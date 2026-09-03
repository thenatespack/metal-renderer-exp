import Metal
import simd
import QuartzCore

/// Streams terrain in around a moving point: each `update`, unloads chunks
/// beyond `unloadRadius` and kicks off background builds (nearest-first) for
/// every missing chunk within `loadRadius` that isn't already in flight.
/// Breaking/placing a block (see Renderer) calls `rebuildAffectedChunks`
/// instead, to re-mesh whatever's already loaded around an edit.
///
/// Chunk generation (noise + meshing) is pure CPU work with no shared mutable
/// state — TerrainGenerator is read-only after init, VillageGenerator is its
/// own lock-protected cache (see its layoutCache), BlockEdits is its own
/// lock-protected store, and Chunk's init only touches its own locals plus
/// MTLDevice, whose resource-creation methods are safe to call concurrently.
/// So builds run in parallel across cores on a background queue and only hop
/// back to the main thread to hand off the finished, immutable Chunk — the
/// render loop is never blocked waiting on one, and replacing an existing
/// entry in loadedChunks means a rebuild never leaves a visible gap: the old
/// mesh keeps rendering right up until the new one is ready.
final class ChunkManager {
    private let device: MTLDevice
    private let generator: TerrainGenerator
    private let villageGenerator: VillageGenerator
    private let blockEdits: BlockEdits
    let chunkSize: Int
    let worldHeight: Int

    var loadRadius = 6
    var unloadRadius = 8

    private(set) var loadedChunks: [ChunkCoord: Chunk] = [:]
    private var pendingCoords: Set<ChunkCoord> = []
    // Last update()'s position, purely to derive moveDirection below —
    // nothing else needs a history of where the player's been.
    private var previousPosition: SIMD3<Float>?
    // How strongly movement direction reorders the (still primarily
    // distance-based) build queue — 0 would be pure nearest-first, 1 would
    // let a far chunk dead ahead completely leapfrog a near one directly
    // behind. See priority(of:centerX:centerZ:moveDirection:).
    private static let directionalBiasStrength: Float = 0.6

    private let buildQueue = DispatchQueue(label: "com.metalrenderer.chunkbuild", qos: .userInitiated, attributes: .concurrent)

    // Benchmark counters, cumulative since launch. Only ever touched on the
    // main thread (update() and the completion handoff below), so no locking.
    private(set) var totalChunksBuilt = 0
    private(set) var totalChunkBuildSeconds: Double = 0
    var averageChunkBuildMs: Double {
        totalChunksBuilt > 0 ? (totalChunkBuildSeconds / Double(totalChunksBuilt)) * 1000 : 0
    }
    var totalTriangleCount: Int {
        loadedChunks.values.reduce(0) { $0 + $1.opaque.indexCount / 3 + $1.water.indexCount / 3 }
    }
    var pendingChunkCount: Int { pendingCoords.count }

    init(device: MTLDevice, generator: TerrainGenerator, villageGenerator: VillageGenerator, blockEdits: BlockEdits, chunkSize: Int, worldHeight: Int) {
        self.device = device
        self.generator = generator
        self.villageGenerator = villageGenerator
        self.blockEdits = blockEdits
        self.chunkSize = chunkSize
        self.worldHeight = worldHeight
    }

    func update(around worldPosition: SIMD3<Float>) {
        let centerX = Int(floor(worldPosition.x / Float(chunkSize)))
        let centerZ = Int(floor(worldPosition.z / Float(chunkSize)))

        // Horizontal heading since the last call — used below to prioritize
        // chunks the player is actually walking toward over ones directly
        // behind them. Tiny deltas (standing still, or paused — update()
        // still runs every frame regardless of Renderer.isPaused) are
        // ignored rather than treated as a real direction, which would
        // otherwise jitter the sort order for no reason.
        var moveDirection = SIMD2<Float>(0, 0)
        if let previousPosition {
            let delta = SIMD2<Float>(worldPosition.x - previousPosition.x, worldPosition.z - previousPosition.z)
            let lengthSq = delta.x * delta.x + delta.y * delta.y
            if lengthSq > 0.0001 {
                moveDirection = delta / lengthSq.squareRoot()
            }
        }
        previousPosition = worldPosition

        for coord in loadedChunks.keys where max(abs(coord.x - centerX), abs(coord.z - centerZ)) > unloadRadius {
            loadedChunks.removeValue(forKey: coord)
        }

        var missing: [ChunkCoord] = []
        for dz in -loadRadius...loadRadius {
            for dx in -loadRadius...loadRadius {
                let coord = ChunkCoord(x: centerX + dx, z: centerZ + dz)
                if loadedChunks[coord] == nil && !pendingCoords.contains(coord) {
                    missing.append(coord)
                }
            }
        }
        guard !missing.isEmpty else { return }

        // Nearest-first, biased toward whatever's ahead of moveDirection —
        // under load, this gets the world the player is about to walk into
        // finished before ones directly behind, instead of a purely radial
        // order that treats every direction the same regardless of heading.
        missing.sort {
            priority(of: $0, centerX: centerX, centerZ: centerZ, moveDirection: moveDirection)
                < priority(of: $1, centerX: centerX, centerZ: centerZ, moveDirection: moveDirection)
        }

        for coord in missing {
            dispatchBuild(coord)
        }
    }

    /// Lower sorts sooner. Base cost is ordinary squared distance from the
    /// player; alignment with moveDirection then discounts that cost for
    /// chunks ahead (dot product near 1) and inflates it for chunks behind
    /// (near -1), scaled by the chunk's own distance so the bias barely
    /// matters for chunks already right next to the player either way.
    private func priority(of coord: ChunkCoord, centerX: Int, centerZ: Int, moveDirection: SIMD2<Float>) -> Float {
        let dx = Float(coord.x - centerX)
        let dz = Float(coord.z - centerZ)
        let distanceSq = dx * dx + dz * dz
        guard distanceSq > 0, moveDirection.x != 0 || moveDirection.y != 0 else { return distanceSq }

        let toChunk = SIMD2<Float>(dx, dz) / distanceSq.squareRoot()
        let alignment = toChunk.x * moveDirection.x + toChunk.y * moveDirection.y // -1...1
        return distanceSq * (1 - Self.directionalBiasStrength * alignment)
    }

    /// Re-meshes whichever currently-loaded chunks a block edit at this
    /// world coordinate could affect: the chunk that owns it, and — since a
    /// chunk's face culling depends on its 1-column border into each
    /// neighbor (see Chunk) — any neighbor (including diagonally, at a
    /// corner) whose border would sample this exact column. Chunks not
    /// currently loaded don't need rebuilding: they'll pick up the edit
    /// correctly the first time they're ever built, same as any other.
    func rebuildAffectedChunks(byEditAt worldCoord: SIMD3<Int>) {
        let cx = Int((Float(worldCoord.x) / Float(chunkSize)).rounded(.down))
        let cz = Int((Float(worldCoord.z) / Float(chunkSize)).rounded(.down))
        let localX = worldCoord.x - cx * chunkSize
        let localZ = worldCoord.z - cz * chunkSize

        let atMinX = localX == 0
        let atMaxX = localX == chunkSize - 1
        let atMinZ = localZ == 0
        let atMaxZ = localZ == chunkSize - 1

        var affected: Set<ChunkCoord> = [ChunkCoord(x: cx, z: cz)]
        if atMinX { affected.insert(ChunkCoord(x: cx - 1, z: cz)) }
        if atMaxX { affected.insert(ChunkCoord(x: cx + 1, z: cz)) }
        if atMinZ { affected.insert(ChunkCoord(x: cx, z: cz - 1)) }
        if atMaxZ { affected.insert(ChunkCoord(x: cx, z: cz + 1)) }
        if atMinX && atMinZ { affected.insert(ChunkCoord(x: cx - 1, z: cz - 1)) }
        if atMinX && atMaxZ { affected.insert(ChunkCoord(x: cx - 1, z: cz + 1)) }
        if atMaxX && atMinZ { affected.insert(ChunkCoord(x: cx + 1, z: cz - 1)) }
        if atMaxX && atMaxZ { affected.insert(ChunkCoord(x: cx + 1, z: cz + 1)) }

        for coord in affected where loadedChunks[coord] != nil {
            dispatchBuild(coord)
        }
    }

    private func dispatchBuild(_ coord: ChunkCoord) {
        guard !pendingCoords.contains(coord) else { return }
        pendingCoords.insert(coord)

        let size = chunkSize
        let height = worldHeight
        buildQueue.async { [device, generator, villageGenerator, blockEdits] in
            let start = CACurrentMediaTime()
            let chunk = Chunk(coord: coord, size: size, worldHeight: height, generator: generator, villageGenerator: villageGenerator, blockEdits: blockEdits, device: device)
            let buildSeconds = CACurrentMediaTime() - start

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingCoords.remove(coord)
                // Terrain (plus any edits already applied) is a pure function
                // of coordinates, so a build that finished late is still
                // perfectly valid data — if it's now outside range, the next
                // update() simply unloads it again.
                self.loadedChunks[coord] = chunk
                self.totalChunksBuilt += 1
                self.totalChunkBuildSeconds += buildSeconds
            }
        }
    }
}
