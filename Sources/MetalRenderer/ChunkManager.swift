import Metal
import simd
import QuartzCore

/// Streams terrain in around a moving point: each `update`, unloads chunks
/// beyond `unloadRadius` and kicks off background builds (nearest-first) for
/// every missing chunk within `loadRadius` that isn't already in flight.
///
/// Chunk generation (noise + meshing) is pure CPU work with no shared mutable
/// state — TerrainGenerator is read-only after init, and Chunk's init only
/// touches its own locals plus MTLDevice, whose resource-creation methods are
/// safe to call concurrently. So builds run in parallel across cores on a
/// background queue and only hop back to the main thread to hand off the
/// finished, immutable Chunk — the render loop is never blocked waiting on one.
final class ChunkManager {
    private let device: MTLDevice
    private let generator: TerrainGenerator
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

    init(device: MTLDevice, generator: TerrainGenerator, chunkSize: Int, worldHeight: Int) {
        self.device = device
        self.generator = generator
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

        let size = chunkSize
        let height = worldHeight
        for coord in missing {
            pendingCoords.insert(coord)
            buildQueue.async { [device, generator] in
                let start = CACurrentMediaTime()
                let chunk = Chunk(coord: coord, size: size, worldHeight: height, generator: generator, device: device)
                let buildSeconds = CACurrentMediaTime() - start

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingCoords.remove(coord)
                    // Terrain is a pure function of coordinates, so a build that
                    // finished late is still perfectly valid data — if it's now
                    // outside range, the next update() simply unloads it again.
                    self.loadedChunks[coord] = chunk
                    self.totalChunksBuilt += 1
                    self.totalChunkBuildSeconds += buildSeconds
                }
            }
        }
    }
}
