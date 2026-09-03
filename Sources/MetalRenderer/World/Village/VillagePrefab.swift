import simd

/// Flat, stateless local-space voxel data for one building shape, rotated and
/// translated into world space by VillageGenerator at query time — no
/// per-instance state exists (or is needed) since every building of the same
/// variant+rotation resolves identically. Local space: x/z span the
/// footprint (origin at the south-west corner), y=0 is the floor. Anything
/// inside the width/depth/height bounding box that isn't listed in `voxels`
/// resolves to `.air` — that's what makes interiors hollow and door/window
/// cutouts read as open without listing every empty cell by hand.
struct VillagePrefab {
    let width: Int   // local X extent
    let depth: Int   // local Z extent
    let height: Int  // local Y extent
    let doorLocal: (x: Int, z: Int) // footprint-edge tile used as the path anchor
    private let voxels: [SIMD3<Int>: VoxelType]

    private init(width: Int, depth: Int, height: Int, doorLocal: (x: Int, z: Int), entries: [(SIMD3<Int>, VoxelType)]) {
        self.width = width
        self.depth = depth
        self.height = height
        self.doorLocal = doorLocal
        // Later entries win — lets a prefab's authoring order (walls, then
        // corner posts, then door/window gaps) override earlier ones simply
        // by being listed after them, instead of needing explicit exclusion.
        self.voxels = Dictionary(entries, uniquingKeysWith: { _, new in new })
    }

    /// World-space footprint size after a given rotation — 90°/270° swap
    /// width and depth. Used by VillageGenerator for overlap checks and to
    /// center a building on a ring position.
    func worldSize(rotation: Int) -> (width: Int, depth: Int) {
        Self.normalized(rotation) % 2 == 0 ? (width, depth) : (depth, width)
    }

    /// World-space position of this building's door tile, given its placement.
    func doorWorldPosition(originX: Int, originZ: Int, rotation: Int) -> (x: Int, z: Int) {
        let (ox, oz) = Self.rotate(doorLocal.x, doorLocal.z, by: rotation)
        return (originX + ox, originZ + oz)
    }

    /// The block at an absolute world coordinate, or nil if it falls outside
    /// this building's rotated/translated footprint entirely — the caller
    /// (VillageLayout) should then fall through to path/open-ground logic.
    func block(worldX: Int, worldY: Int, worldZ: Int, originX: Int, originZ: Int, baseY: Int, rotation: Int) -> VoxelType? {
        let dx = worldX - originX
        let dz = worldZ - originZ
        let inverseRotation = (4 - Self.normalized(rotation)) % 4
        let (lx, lz) = Self.rotate(dx, dz, by: inverseRotation)
        let ly = worldY - baseY
        guard (0..<width).contains(lx), (0..<depth).contains(lz), (0..<height).contains(ly) else { return nil }
        return voxels[SIMD3(lx, ly, lz)] ?? .air
    }

    private static func normalized(_ rotation: Int) -> Int { ((rotation % 4) + 4) % 4 }

    /// Rotates a local-space (x, z) offset by rotation*90°, CCW, integer-only
    /// (no trig — every rotation here is an exact quarter turn).
    private static func rotate(_ x: Int, _ z: Int, by rotation: Int) -> (x: Int, z: Int) {
        switch normalized(rotation) {
        case 0: return (x, z)
        case 1: return (-z, x)
        case 2: return (-x, -z)
        default: return (z, -x)
        }
    }
}

extension VillagePrefab {
    /// A fully filled cuboid — floors, roofs, solid fills.
    private static func box(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ z0: Int, _ z1: Int, type: VoxelType) -> [(SIMD3<Int>, VoxelType)] {
        var entries: [(SIMD3<Int>, VoxelType)] = []
        for y in y0...y1 { for z in z0...z1 { for x in x0...x1 {
            entries.append((SIMD3(x, y, z), type))
        }}}
        return entries
    }

    /// Only the outer ring of an x/z footprint, across the full y range —
    /// walls, hollow in the middle so the interior reads as .air.
    private static func perimeter(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ z0: Int, _ z1: Int, type: VoxelType) -> [(SIMD3<Int>, VoxelType)] {
        var entries: [(SIMD3<Int>, VoxelType)] = []
        for y in y0...y1 { for z in z0...z1 { for x in x0...x1 {
            guard x == x0 || x == x1 || z == z0 || z == z1 else { continue }
            entries.append((SIMD3(x, y, z), type))
        }}}
        return entries
    }

    /// A vertical column, used for corner posts.
    private static func post(_ x: Int, _ z: Int, _ y0: Int, _ y1: Int, type: VoxelType) -> [(SIMD3<Int>, VoxelType)] {
        (y0...y1).map { (SIMD3(x, $0, z), type) }
    }

    /// An air cutout in a wall — door or window gap. Appended after the wall
    /// entries it punches through, so the "later entries win" rule clears it.
    private static func gap(_ x: Int, _ y0: Int, _ y1: Int, _ z: Int) -> [(SIMD3<Int>, VoxelType)] {
        (y0...y1).map { (SIMD3(x, $0, z), VoxelType.air) }
    }

    /// 5x5x4 — mud-brick walls, thatch roof, one door.
    static let smallHut = VillagePrefab(
        width: 5, depth: 5, height: 4, doorLocal: (2, 0),
        entries: box(0, 4, 0, 0, 0, 4, type: .packedDirt)
            + perimeter(0, 4, 1, 2, 0, 4, type: .mudBricks)
            + box(0, 4, 3, 3, 0, 4, type: .thatch)
            + gap(2, 1, 2, 0)
    )

    /// 7x6x5 — plank walls with a log-cabin corner frame, a stepped thatch
    /// roofline (cheap "ridge" read without true sloped geometry), one door,
    /// one window.
    static let mediumHouse = VillagePrefab(
        width: 7, depth: 6, height: 5, doorLocal: (3, 0),
        entries: box(0, 6, 0, 0, 0, 5, type: .planks)
            + perimeter(0, 6, 1, 2, 0, 5, type: .planks)
            + post(0, 0, 1, 2, type: .wood) + post(6, 0, 1, 2, type: .wood)
            + post(0, 5, 1, 2, type: .wood) + post(6, 5, 1, 2, type: .wood)
            + box(0, 6, 3, 3, 0, 5, type: .thatch)
            + box(2, 4, 4, 4, 2, 3, type: .thatch)
            + gap(3, 1, 2, 0)
            + gap(0, 1, 1, 2)
    )

    /// 9x7x6 — stone-brick walls, a reinforced-planks roof, one door, two windows.
    static let largeHall = VillagePrefab(
        width: 9, depth: 7, height: 6, doorLocal: (4, 0),
        entries: box(0, 8, 0, 0, 0, 6, type: .polishedStone)
            + perimeter(0, 8, 1, 4, 0, 6, type: .stoneBricks)
            + box(0, 8, 5, 5, 0, 6, type: .reinforcedPlanks)
            + gap(4, 1, 2, 0)
            + gap(0, 2, 2, 2)
            + gap(0, 2, 2, 4)
    )

    static let all: [VillagePrefab] = [smallHut, mediumHouse, largeHall]
}
