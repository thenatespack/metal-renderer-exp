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
/// state — TerrainGenerator is read-only after init, BlockEdits is its own
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
    private let blockEdits: BlockEdits
    let chunkSize: Int
    let worldHeight: Int

    var loadRadius = 6
    var unloadRadius = 8

    private(set) var loadedChunks: [ChunkCoord: Chunk] = [:]
    private var pendingCoords: Set<ChunkCoord> = []

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

    init(device: MTLDevice, generator: TerrainGenerator, blockEdits: BlockEdits, chunkSize: Int, worldHeight: Int) {
        self.device = device
        self.generator = generator
        self.blockEdits = blockEdits
        self.chunkSize = chunkSize
        self.worldHeight = worldHeight
    }

    func update(around worldPosition: SIMD3<Float>) {
        let centerX = Int(floor(worldPosition.x / Float(chunkSize)))
        let centerZ = Int(floor(worldPosition.z / Float(chunkSize)))

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

        // Nearest-first so, under load, the chunks right around the camera
        // tend to finish (and thus appear) before farther-out ones.
        missing.sort { a, b in
            let da = (a.x - centerX) * (a.x - centerX) + (a.z - centerZ) * (a.z - centerZ)
            let db = (b.x - centerX) * (b.x - centerX) + (b.z - centerZ) * (b.z - centerZ)
            return da < db
        }

        for coord in missing {
            dispatchBuild(coord)
        }
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
        buildQueue.async { [device, generator, blockEdits] in
            let start = CACurrentMediaTime()
            let chunk = Chunk(coord: coord, size: size, worldHeight: height, generator: generator, blockEdits: blockEdits, device: device)
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
