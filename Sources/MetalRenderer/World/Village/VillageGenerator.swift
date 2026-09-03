import Foundation
import simd

private struct CellCoord: Hashable { let x: Int; let z: Int }

/// One 1x1 world-space column that's part of a village's road network.
struct PathTile: Hashable { let x: Int; let z: Int }

/// One building's placement within its village — a rotation/translation of
/// a stateless VillagePrefab, plus the derived world-space info
/// VillageGenerator needs for overlap checks and path routing.
struct BuildingPlacement {
    let originX: Int
    let originZ: Int
    let rotation: Int
    let prefab: VillagePrefab

    var doorWorldPosition: (x: Int, z: Int) {
        prefab.doorWorldPosition(originX: originX, originZ: originZ, rotation: rotation)
    }

    var worldBounds: (minX: Int, maxX: Int, minZ: Int, maxZ: Int) {
        let size = prefab.worldSize(rotation: rotation)
        return (originX, originX + size.width - 1, originZ, originZ + size.depth - 1)
    }
}

/// One village's full deterministic layout — computed once per cell and
/// cached (see VillageGenerator.cachedLayout), then queried per-voxel.
struct VillageLayout {
    let centerX: Int
    let centerZ: Int
    let flattenedHeight: Int
    let buildings: [BuildingPlacement]
    let pathTiles: Set<PathTile>

    /// A building or path block at this coordinate, or nil if it's open
    /// yard within the footprint (handled by VillageGenerator.block's
    /// flattened-fill fallback) or outside every building's own bounds.
    func structureBlock(x: Int, y: Int, z: Int) -> VoxelType? {
        for building in buildings {
            if let block = building.prefab.block(
                worldX: x, worldY: y, worldZ: z,
                originX: building.originX, originZ: building.originZ,
                baseY: flattenedHeight, rotation: building.rotation
            ) {
                return block
            }
        }
        if y == flattenedHeight, pathTiles.contains(PathTile(x: x, z: z)) {
            return .packedDirt
        }
        return nil
    }

    /// The block at (x, y, z), given that (x, z) is already known to be
    /// within this village's footprint radius: a building/path block if
    /// there is one, else the flattened yard fill.
    fileprivate func resolvedBlock(x: Int, y: Int, z: Int) -> VoxelType {
        if let block = structureBlock(x: x, y: y, z: z) { return block }
        if y > flattenedHeight { return .air }
        if y >= flattenedHeight - 3 { return .dirt }
        return .stone
    }
}

/// A pre-resolved, lock-free per-chunk handle for querying village blocks —
/// see VillageGenerator.query. Cheap to call per voxel: no cache lookup, no
/// locking, just an arithmetic distance check against the one village (if
/// any) already determined to be relevant to this chunk.
struct VillageQuery {
    fileprivate let layout: VillageLayout?

    func block(x: Int, y: Int, z: Int) -> VoxelType? {
        guard let layout else { return nil }
        let dx = x - layout.centerX
        let dz = z - layout.centerZ
        guard dx * dx + dz * dz <= VillageGenerator.footprintRadius * VillageGenerator.footprintRadius else { return nil }
        return layout.resolvedBlock(x: x, y: y, z: z)
    }
}

/// Stateless (given a seed) village placement, mirroring TerrainGenerator's
/// treeBlock pattern at structure scale: `block(x:y:z:)` is a pure function
/// of absolute world voxel coordinates, deterministic and unpersisted, so a
/// village always regenerates identically on reload — player edits still win
/// over it via BlockEdits, exactly like they do over natural terrain/trees.
///
/// Holds a read-only reference to TerrainGenerator (one-directional
/// dependency — TerrainGenerator itself is never modified or made aware of
/// villages) to reuse its column/biome/carve queries when deciding where a
/// village can go.
final class VillageGenerator {
    private let seed: UInt64
    private let terrainGenerator: TerrainGenerator

    // Villages sit on a grid of cells much larger than a single village's
    // own footprint (mirrors treeBlock's jittered-cell trick, just at
    // structure scale instead of single-tree scale). The jittered center is
    // additionally confined to the *middle half* of its cell (see `layout`)
    // so that even in the worst case — two adjacent cells both rolling a
    // village and jittering toward their shared border — the two centers
    // can never end up closer than cellSize/2, which comfortably exceeds
    // 2*footprintRadius: villages can never overlap.
    private static let villageCellSize = 192
    private static let villageChance: Float = 0.55
    // fileprivate (not private) so VillageQuery, a separate top-level type
    // in this file, can share the same footprint-radius check without
    // needing its own copy — see VillageGenerator.query.
    fileprivate static let footprintRadius = 40
    // Biome amplitude alone (Biome.amplitude) runs 5...9, so a tolerance
    // much tighter than that rejects nearly every candidate site — flattened
    // fill (see VillageGenerator.block) absorbs the difference regardless,
    // the cost is just a taller boundary "cliff" where the flattened pad
    // meets natural terrain, which is an accepted v1 limitation (see this
    // type's header comment).
    private static let flatnessTolerance = 10
    private static let minHeightAboveSeaLevel = 3
    private static let ringSampleCount = 12

    // Real work (13 columnInfo samples + building placement) happens once
    // per cell in `layout`, cached behind a lock since Chunk/Renderer query
    // this from ChunkManager's concurrent background build queue — same
    // thread-safety idiom as BlockEdits.
    private let lock = NSLock()
    private var layoutCache: [CellCoord: VillageLayout?] = [:]

    init(seed: UInt64, terrainGenerator: TerrainGenerator) {
        // Offset so village rolls are independent of TerrainGenerator's own
        // internal noise/tree seeds (seed, seed+1...seed+6).
        self.seed = seed &+ 9001
        self.terrainGenerator = terrainGenerator
    }

    /// Non-nil for every (x, y, z) inside a village's flattened footprint —
    /// this fully replaces tree/cave/natural-height terrain logic for that
    /// column, which is why callers (Chunk.voxelAt, Renderer.blockAt) must
    /// check this *before* falling through to TerrainGenerator, not blend
    /// the two.
    func block(x: Int, y: Int, z: Int) -> VoxelType? {
        guard let village = containingVillage(x: x, z: z) else { return nil }
        return village.resolvedBlock(x: x, y: y, z: z)
    }

    /// Resolves once per chunk build which village (if any) could reach into
    /// that chunk's bounds, returning a lock-free handle the chunk's
    /// per-voxel mesh loop can then query directly. `block(x:y:z:)` above
    /// goes through `containingVillage`'s lock-protected 3x3-cell cache
    /// lookup on *every* call — fine for Renderer's occasional per-frame
    /// collision/raycast queries, but Chunk's mesher calls its voxel
    /// function on the order of tens of thousands of times per chunk, and
    /// paying that lookup cost that many times (across many chunks building
    /// concurrently) is what caused the pathological slowdown this type
    /// exists to fix.
    func query(chunkOriginX: Int, chunkOriginZ: Int, chunkSize: Int) -> VillageQuery {
        let chunkCenterX = chunkOriginX + chunkSize / 2
        let chunkCenterZ = chunkOriginZ + chunkSize / 2
        // Generous margin: a village whose center is this far from the
        // chunk's own center could still have footprint or building geometry
        // reaching into the chunk.
        let reach = Float(Self.footprintRadius + chunkSize)
        let layout = nearbyVillageLayouts(x: chunkCenterX, z: chunkCenterZ).first {
            let dx = Float($0.centerX - chunkCenterX)
            let dz = Float($0.centerZ - chunkCenterZ)
            return dx * dx + dz * dz <= reach * reach
        }
        return VillageQuery(layout: layout)
    }

    /// The flattened ground-surface height at (x, z), or nil outside any
    /// village. Renderer's groundHeight has a fast path that skips blockAt
    /// entirely when a column has no edits and isn't carved — without this,
    /// that fast path would report the *natural* terrain height under a
    /// village, disagreeing with the flattened blocks the player actually
    /// stands on.
    func flattenedHeight(x: Int, z: Int) -> Int? {
        containingVillage(x: x, z: z)?.flattenedHeight
    }

    /// Every village whose cell falls in the 3x3 neighborhood around (x, z),
    /// regardless of the tighter footprintRadius check `block`/
    /// `flattenedHeight` use — VillagerManager uses this to find candidate
    /// villages to activate/deactivate based on distance to the player,
    /// which needs a wider net than "is this exact column inside a footprint."
    func nearbyVillageLayouts(x: Int, z: Int) -> [VillageLayout] {
        let cellX = Int((Float(x) / Float(Self.villageCellSize)).rounded(.down))
        let cellZ = Int((Float(z) / Float(Self.villageCellSize)).rounded(.down))
        var results: [VillageLayout] = []
        for dcz in -1...1 {
            for dcx in -1...1 {
                if let layout = cachedLayout(cellX: cellX + dcx, cellZ: cellZ + dcz) {
                    results.append(layout)
                }
            }
        }
        return results
    }

    private func containingVillage(x: Int, z: Int) -> VillageLayout? {
        let cellX = Int((Float(x) / Float(Self.villageCellSize)).rounded(.down))
        let cellZ = Int((Float(z) / Float(Self.villageCellSize)).rounded(.down))
        for dcz in -1...1 {
            for dcx in -1...1 {
                guard let layout = cachedLayout(cellX: cellX + dcx, cellZ: cellZ + dcz) else { continue }
                let dx = x - layout.centerX
                let dz = z - layout.centerZ
                guard dx * dx + dz * dz <= Self.footprintRadius * Self.footprintRadius else { continue }
                return layout
            }
        }
        return nil
    }

    private func cachedLayout(cellX: Int, cellZ: Int) -> VillageLayout? {
        lock.lock()
        defer { lock.unlock() }
        let key = CellCoord(x: cellX, z: cellZ)
        if let cached = layoutCache[key] { return cached }
        let computed = layout(cellX: cellX, cellZ: cellZ)
        layoutCache[key] = computed
        return computed
    }

    private func layout(cellX: Int, cellZ: Int) -> VillageLayout? {
        guard hash01(cellX, cellZ, 0) < Self.villageChance else { return nil }

        // Confined to the middle half of the cell — see the type's header
        // comment on why this is what actually guarantees non-overlap.
        let quarter = Self.villageCellSize / 4
        let half = Self.villageCellSize / 2
        let centerX = cellX * Self.villageCellSize + quarter + Int(hash01(cellX, cellZ, 1) * Float(half))
        let centerZ = cellZ * Self.villageCellSize + quarter + Int(hash01(cellX, cellZ, 2) * Float(half))

        let centerInfo = terrainGenerator.columnInfo(x: centerX, z: centerZ)
        guard centerInfo.topBlock == .grass,
              centerInfo.height > TerrainGenerator.seaLevel + Self.minHeightAboveSeaLevel,
              !terrainGenerator.isCarved(x: centerX, y: centerInfo.height, z: centerZ, surfaceHeight: centerInfo.height)
        else { return nil }

        // Coarse ring sample (cheap — done once per candidate cell, not per
        // voxel) rather than checking every column in the footprint: reject
        // sites that are too bumpy, dip into a different biome, or graze a
        // cave/ravine mouth.
        var minHeight = centerInfo.height
        var maxHeight = centerInfo.height
        let ringRadius = Float(Self.footprintRadius) * 0.8
        for i in 0..<Self.ringSampleCount {
            let angle = (Float(i) / Float(Self.ringSampleCount)) * 2 * Float.pi
            let sx = centerX + Int((cos(angle) * ringRadius).rounded())
            let sz = centerZ + Int((sin(angle) * ringRadius).rounded())
            let info = terrainGenerator.columnInfo(x: sx, z: sz)
            guard info.topBlock == .grass,
                  !terrainGenerator.isCarved(x: sx, y: info.height, z: sz, surfaceHeight: info.height)
            else { return nil }
            minHeight = min(minHeight, info.height)
            maxHeight = max(maxHeight, info.height)
        }
        guard maxHeight - minHeight <= Self.flatnessTolerance else { return nil }
        // Min, not average/center height, so no building ever floats above a
        // hidden dip elsewhere in the footprint.
        let flattenedHeight = minHeight

        let buildingCount = 3 + Int(hash01(cellX, cellZ, 10) * 3) // 3...5
        var buildings: [BuildingPlacement] = []
        for i in 0..<buildingCount {
            // Evenly-spaced ring position, jittered in both angle and radius
            // so buildings don't read as a perfectly regular polygon, all
            // facing inward toward the village center.
            let angle = (Float(i) / Float(buildingCount)) * 2 * Float.pi + (hash01(cellX, cellZ, 20 + i) - 0.5) * 0.5
            let radius = Float(Self.footprintRadius) * (0.45 + hash01(cellX, cellZ, 30 + i) * 0.35)
            let ringX = centerX + Int((cos(angle) * radius).rounded())
            let ringZ = centerZ + Int((sin(angle) * radius).rounded())

            let prefabIndex = Int(hash01(cellX, cellZ, 40 + i) * Float(VillagePrefab.all.count)) % VillagePrefab.all.count
            let prefab = VillagePrefab.all[prefabIndex]
            let rotation = Int(hash01(cellX, cellZ, 50 + i) * 4) % 4
            let size = prefab.worldSize(rotation: rotation)
            let originX = ringX - size.width / 2
            let originZ = ringZ - size.depth / 2
            let candidate = BuildingPlacement(originX: originX, originZ: originZ, rotation: rotation, prefab: prefab)

            // Reject (skip, don't abort the whole village) if this would
            // overlap an already-accepted building, with a small margin so
            // adjacent houses don't read as fused together.
            let bounds = candidate.worldBounds
            let overlaps = buildings.contains { existing in
                let eb = existing.worldBounds
                return bounds.minX - 2 <= eb.maxX && bounds.maxX + 2 >= eb.minX
                    && bounds.minZ - 2 <= eb.maxZ && bounds.maxZ + 2 >= eb.minZ
            }
            guard !overlaps else { continue }
            buildings.append(candidate)
        }
        guard !buildings.isEmpty else { return nil }

        // Simple hub-and-spoke road: a straight line from each building's
        // door to the village center, no pathfinding needed. Dilated by one
        // tile in each direction so it reads as a road, not a single-block
        // trail easy to miss while walking beside it.
        var pathTiles: Set<PathTile> = []
        for building in buildings {
            for point in Self.line(from: building.doorWorldPosition, to: (centerX, centerZ)) {
                pathTiles.insert(PathTile(x: point.x, z: point.z))
                pathTiles.insert(PathTile(x: point.x + 1, z: point.z))
                pathTiles.insert(PathTile(x: point.x - 1, z: point.z))
                pathTiles.insert(PathTile(x: point.x, z: point.z + 1))
                pathTiles.insert(PathTile(x: point.x, z: point.z - 1))
            }
        }

        return VillageLayout(centerX: centerX, centerZ: centerZ, flattenedHeight: flattenedHeight, buildings: buildings, pathTiles: pathTiles)
    }

    /// Integer Bresenham line between two points, inclusive of both ends.
    private static func line(from a: (x: Int, z: Int), to b: (x: Int, z: Int)) -> [(x: Int, z: Int)] {
        var points: [(x: Int, z: Int)] = []
        var x0 = a.x, z0 = a.z
        let x1 = b.x, z1 = b.z
        let dx = abs(x1 - x0), dz = abs(z1 - z0)
        let sx = x0 < x1 ? 1 : -1
        let sz = z0 < z1 ? 1 : -1
        var err = dx - dz
        while true {
            points.append((x0, z0))
            if x0 == x1 && z0 == z1 { break }
            let e2 = 2 * err
            if e2 > -dz { err -= dz; x0 += sx }
            if e2 < dx { err += dx; z0 += sz }
        }
        return points
    }

    /// Deterministic [0, 1) hash of (a, b, salt) plus this generator's own
    /// (offset) seed. Duplicated from TerrainGenerator's private primitive
    /// rather than shared — that one is private, and duplicating ~12 lines
    /// is lower-risk than widening TerrainGenerator's API for this.
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
