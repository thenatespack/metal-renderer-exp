/// A column's resolved height and block palette, as decided by TerrainGenerator.
struct ColumnInfo {
    let height: Int
    let biome: Biome
    let topBlock: VoxelType
    let subBlock: VoxelType
}

/// Stateless (given a seed) terrain generator: `columnInfo(x:z:)` and
/// `treeBlock(x:y:z:)` are pure functions of absolute world voxel coordinates.
/// That statelessness is what makes infinite chunked terrain simple here — a
/// chunk can resolve its border columns (for face culling against
/// not-yet-built neighbor chunks), and tree canopies that overhang into a
/// neighboring chunk, just by calling these again with coordinates outside
/// its own range, instead of needing the actual neighbor chunk to exist yet.
final class TerrainGenerator {
    static let seaLevel = 9
    private static let mountainRockLevel = 28
    private static let mountainSnowLevel = 34
    private static let continentalStrength: Float = 20

    // Trees are placed on a jittered grid: one candidate slot per `treeCellSize`
    // x `treeCellSize` cell, at a per-cell random offset. Canopy radius is kept
    // smaller than the cell size, so a query point only ever needs to check the
    // 3x3 neighborhood of cells around it to find every tree that could reach it.
    private static let treeCellSize = 5
    private static let treeCanopyRadius = 2
    private static let treeTrunkHeight = 4
    /// How far above a column's own ground height it's worth calling `treeBlock`
    /// at all: trunk + top leaf layer, plus slack for neighboring columns being
    /// a bit taller/shorter than the query column itself.
    static let treeSearchBand = 8

    private let worldHeight: Int
    private let seed: UInt64
    private let detailNoise: PerlinNoise
    private let continentalNoise: PerlinNoise
    private let temperatureNoise: PerlinNoise
    private let moistureNoise: PerlinNoise

    init(seed: UInt64, worldHeight: Int) {
        self.worldHeight = worldHeight
        self.seed = seed
        detailNoise = PerlinNoise(seed: seed)
        continentalNoise = PerlinNoise(seed: seed &+ 1)
        temperatureNoise = PerlinNoise(seed: seed &+ 2)
        moistureNoise = PerlinNoise(seed: seed &+ 3)
    }

    func columnInfo(x: Int, z: Int) -> ColumnInfo {
        let fx = Float(x)
        let fz = Float(z)

        let detail = detailNoise.fbm(x: fx * 0.035, y: fz * 0.035, octaves: 4)
        let continental = continentalNoise.fbm(x: fx * 0.006, y: fz * 0.006, octaves: 3)
        let temperature = temperatureNoise.fbm(x: fx * 0.008, y: fz * 0.008, octaves: 2) * 0.5 + 0.5
        let moisture = moistureNoise.fbm(x: fx * 0.010, y: fz * 0.010, octaves: 2) * 0.5 + 0.5

        let biome = Biome.select(temperature: temperature, moisture: moisture)
        let rawHeight = biome.baseHeight + detail * biome.amplitude + continental * Self.continentalStrength
        let height = max(1, min(worldHeight - 2, Int(rawHeight.rounded())))

        let topBlock: VoxelType
        let subBlock: VoxelType
        if height <= Self.seaLevel {
            topBlock = .sand
            subBlock = .sand
        } else if height >= Self.mountainSnowLevel {
            topBlock = .snow
            subBlock = .stone
        } else if height >= Self.mountainRockLevel {
            topBlock = .stone
            subBlock = .stone
        } else {
            topBlock = biome.surfaceBlock
            subBlock = biome.subsurfaceBlock
        }

        return ColumnInfo(height: height, biome: biome, topBlock: topBlock, subBlock: subBlock)
    }

    /// Wood/leaves at an absolute point above the terrain, or nil if none.
    /// Only worth calling when `y` is a handful of blocks above that column's
    /// own ground height (see Chunk's `treeSearchBand` fast-reject).
    func treeBlock(x: Int, y: Int, z: Int) -> VoxelType? {
        let cellX = Int((Float(x) / Float(Self.treeCellSize)).rounded(.down))
        let cellZ = Int((Float(z) / Float(Self.treeCellSize)).rounded(.down))

        for dcz in -1...1 {
            for dcx in -1...1 {
                let cx = cellX + dcx
                let cz = cellZ + dcz

                let jitterX = Int(hash01(cx, cz, 0) * Float(Self.treeCellSize))
                let jitterZ = Int(hash01(cx, cz, 1) * Float(Self.treeCellSize))
                let trunkX = cx * Self.treeCellSize + jitterX
                let trunkZ = cz * Self.treeCellSize + jitterZ

                let dx = x - trunkX
                let dz = z - trunkZ
                guard abs(dx) <= Self.treeCanopyRadius, abs(dz) <= Self.treeCanopyRadius else { continue }

                let info = columnInfo(x: trunkX, z: trunkZ)
                guard info.topBlock == .grass, info.biome.treeDensity > 0 else { continue }
                guard hash01(cx, cz, 2) < info.biome.treeDensity else { continue }

                if let block = Self.treeShapeBlock(dx: dx, dz: dz, dyAboveGround: y - info.height) {
                    return block
                }
            }
        }
        return nil
    }

    private static func treeShapeBlock(dx: Int, dz: Int, dyAboveGround: Int) -> VoxelType? {
        if dx == 0, dz == 0, dyAboveGround >= 1, dyAboveGround <= treeTrunkHeight {
            return .wood
        }
        let canopyLayers: [(y: Int, radius: Int)] = [
            (treeTrunkHeight - 1, 2), (treeTrunkHeight, 2), (treeTrunkHeight + 1, 1),
        ]
        for layer in canopyLayers where layer.y == dyAboveGround {
            if dx * dx + dz * dz <= layer.radius * layer.radius {
                return .leaves
            }
        }
        return nil
    }

    /// Deterministic [0, 1) hash of (a, b, salt, seed). Cheap integer mixing —
    /// used to reject the overwhelming majority of tree cell candidates before
    /// ever touching the noise-based `columnInfo`.
    private func hash01(_ a: Int, _ b: Int, _ salt: Int) -> Float {
        var h = UInt64(bitPattern: Int64(a)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2AE3D27D4EB4F
        h ^= UInt64(bitPattern: Int64(salt)) &* 0x165667B19E3779F9
        h ^= seed
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        h ^= h >> 31
        return Float(h & 0xFF_FFFF) / Float(0xFF_FFFF)
    }
}
