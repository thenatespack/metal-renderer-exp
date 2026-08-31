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
    /// How far above a column's own ground height it's worth calling `treeBlock`
    /// at all: tallest possible trunk + top leaf layer (see treeShapeBlock's
    /// "tall and narrow" species, the largest), plus slack for neighboring
    /// columns being a bit taller/shorter than the query column itself.
    static let treeSearchBand = 10

    // Caves: two independent 2D fields, each sampled on a different plane
    // (x paired with y, z paired with y) — real 3D Perlin isn't implemented,
    // but this cheap combination gives well-known "wormy" tunnels for free,
    // since a*a+b*b only stays small where BOTH fields cross zero at once,
    // tracing out winding lines through space rather than isolated blobs.
    private static let caveFrequency: Float = 0.05
    private static let caveVerticalStretch: Float = 1.6 // taller noise-Y frequency so tunnels read as roughly horizontal, not perfectly round
    private static let caveThreshold: Float = 0.03
    // Never carve the first few blocks under the surface (unlike ravines,
    // caves shouldn't pockmark the ground with random 1-block sinkholes) or
    // right down at the world floor.
    private static let caveMinDepthBelowSurface = 3
    private static let caveMinY = 3

    // Ravines: a single ridge-noise field over (x, z) — |noise| dips toward
    // zero along winding lines, and threshold-ing that near zero picks out a
    // network of thin bands across the map, open from near the surface down
    // to ravineMaxDepth. Column-only (no y term) so the same gash lines up
    // straight down rather than wandering per-layer like a cave would.
    private static let ravineFrequency: Float = 0.01
    private static let ravineThreshold: Float = 0.014
    private static let ravineMaxDepth = 28

    private let worldHeight: Int
    private let seed: UInt64
    private let detailNoise: PerlinNoise
    private let continentalNoise: PerlinNoise
    private let temperatureNoise: PerlinNoise
    private let moistureNoise: PerlinNoise
    private let caveNoiseA: PerlinNoise
    private let caveNoiseB: PerlinNoise
    private let ravineNoise: PerlinNoise

    init(seed: UInt64, worldHeight: Int) {
        self.worldHeight = worldHeight
        self.seed = seed
        detailNoise = PerlinNoise(seed: seed)
        continentalNoise = PerlinNoise(seed: seed &+ 1)
        temperatureNoise = PerlinNoise(seed: seed &+ 2)
        moistureNoise = PerlinNoise(seed: seed &+ 3)
        caveNoiseA = PerlinNoise(seed: seed &+ 4)
        caveNoiseB = PerlinNoise(seed: seed &+ 5)
        ravineNoise = PerlinNoise(seed: seed &+ 6)
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

                // Species and height are picked once per tree (salted by this
                // cell's own coordinates, same as its trunk position), not
                // per query point — so a given tree looks the same from every
                // angle instead of picking a new shape per voxel.
                let speciesRoll = hash01(cx, cz, 3)
                let heightRoll = hash01(cx, cz, 4)
                if let block = Self.treeShapeBlock(dx: dx, dz: dz, dyAboveGround: y - info.height, speciesRoll: speciesRoll, heightRoll: heightRoll) {
                    return block
                }
            }
        }
        return nil
    }

    /// Three rough species, picked per-tree by `speciesRoll` so a forest
    /// doesn't read as one canopy shape copy-pasted everywhere; `heightRoll`
    /// then jitters trunk height a little within whichever was picked, for
    /// variety even among trees of the same species. Purely a function of
    /// the two rolls (already deterministic per tree cell) plus the query
    /// offset — no other state.
    private static func treeShapeBlock(dx: Int, dz: Int, dyAboveGround: Int, speciesRoll: Float, heightRoll: Float) -> VoxelType? {
        let trunkHeight: Int
        let canopyLayers: [(y: Int, radius: Int)]

        if speciesRoll < 0.35 {
            // Short and bushy.
            trunkHeight = 3
            canopyLayers = [(2, 2), (3, 2), (4, 1)]
        } else if speciesRoll < 0.75 {
            // Standard — close to the original single fixed shape.
            trunkHeight = 4 + Int(heightRoll * 2) // 4 or 5
            canopyLayers = [(trunkHeight - 1, 2), (trunkHeight, 2), (trunkHeight + 1, 1)]
        } else {
            // Tall and narrow.
            trunkHeight = 6 + Int(heightRoll * 2) // 6 or 7
            canopyLayers = [(trunkHeight - 2, 1), (trunkHeight - 1, 2), (trunkHeight, 1), (trunkHeight + 1, 1)]
        }

        if dx == 0, dz == 0, dyAboveGround >= 1, dyAboveGround <= trunkHeight {
            return .wood
        }
        for layer in canopyLayers where layer.y == dyAboveGround {
            if dx * dx + dz * dz <= layer.radius * layer.radius {
                return .leaves
            }
        }
        return nil
    }

    /// The purely procedural block at an absolute world coordinate, ignoring
    /// player edits entirely — that's layered on top by whoever calls this
    /// (Chunk for meshing, Renderer for collision/raycasts). Recomputes
    /// `columnInfo` fresh on every call rather than caching, which is fine
    /// for the low call volumes those two use it at (a handful of samples a
    /// frame), but would be far too slow for Chunk's actual per-voxel mesh
    /// loop — that path keeps its own cached-per-column table instead of
    /// calling this.
    func proceduralBlock(x: Int, y: Int, z: Int, worldHeight: Int) -> VoxelType {
        if y < 0 { return .stone }
        if y >= worldHeight { return .air }

        let info = columnInfo(x: x, z: z)
        if y > info.height {
            if y <= info.height + Self.treeSearchBand, let tree = treeBlock(x: x, y: y, z: z) {
                return tree
            }
            return y <= Self.seaLevel ? .water : .air
        }
        guard !isCarved(x: x, y: y, z: z, surfaceHeight: info.height) else { return .air }
        if y == info.height {
            return info.topBlock
        } else if y >= info.height - 3 {
            return info.subBlock
        } else {
            return .stone
        }
    }

    /// True if this underground point should be hollowed into open air —
    /// caves or ravines (see their constants above). Never carves under
    /// water: a carved seafloor would open straight into the ocean above
    /// with no way for these purely-per-voxel rules to seal the gap back
    /// up, since water generation (see proceduralBlock/Chunk.voxelAt) has
    /// no idea a cave was carved beneath it.
    func isCarved(x: Int, y: Int, z: Int, surfaceHeight: Int) -> Bool {
        guard surfaceHeight > Self.seaLevel, y >= Self.caveMinY else { return false }
        if isRavine(x: x, y: y, z: z, surfaceHeight: surfaceHeight) { return true }
        guard y <= surfaceHeight - Self.caveMinDepthBelowSurface else { return false }
        return isCave(x: x, y: y, z: z)
    }

    private func isCave(x: Int, y: Int, z: Int) -> Bool {
        // Single-octave: this runs per-voxel across every solid block in a
        // chunk (see Chunk.voxelAt), so it's worth keeping cheap — plain
        // Perlin noise still gives smooth, organic-looking tunnels without
        // fbm's extra noise() calls per query.
        let fx = Float(x) * Self.caveFrequency
        let fy = Float(y) * Self.caveFrequency * Self.caveVerticalStretch
        let fz = Float(z) * Self.caveFrequency
        let a = caveNoiseA.noise(x: fx, y: fy)
        let b = caveNoiseB.noise(x: fz, y: fy)
        return a * a + b * b < Self.caveThreshold
    }

    private func isRavine(x: Int, y: Int, z: Int, surfaceHeight: Int) -> Bool {
        guard y >= surfaceHeight - Self.ravineMaxDepth else { return false }
        let ridge = ravineNoise.noise(x: Float(x) * Self.ravineFrequency, y: Float(z) * Self.ravineFrequency)
        // Narrower toward the bottom of its depth range, so a ravine reads
        // as a tapering gash rather than a uniform-width slot cut straight down.
        let depthFraction = Float(surfaceHeight - y) / Float(Self.ravineMaxDepth)
        let width = Self.ravineThreshold * (1 - min(max(depthFraction, 0), 1) * 0.7)
        return abs(ridge) < width
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
