import simd
import Foundation

struct BlockCoord: Hashable, Codable {
    let x: Int
    let y: Int
    let z: Int

    init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ v: SIMD3<Int>) {
        x = v.x
        y = v.y
        z = v.z
    }
}

/// Sparse overrides on top of the procedural world — every block a player has
/// broken (set to .air) or placed. Consulted ahead of TerrainGenerator/tree
/// lookups by both Chunk (meshing) and Renderer (collision, raycasts), so an
/// edit always wins over whatever would otherwise generate there, and world
/// state and collision can never disagree about it.
///
/// Thread-safe: chunk (re)builds read this from background threads and can
/// run concurrently with a main-thread edit from breaking/placing a block.
final class BlockEdits {
    private var edits: [BlockCoord: VoxelType] = [:]
    private let lock = NSLock()

    func set(_ coord: BlockCoord, to type: VoxelType) {
        lock.lock()
        edits[coord] = type
        lock.unlock()
    }

    func get(_ coord: BlockCoord) -> VoxelType? {
        lock.lock()
        defer { lock.unlock() }
        return edits[coord]
    }

    /// Bulk-replaces every edit — used once at startup to restore a save
    /// file, before any chunk has been built or any query made against this.
    func load(_ savedEdits: [BlockCoord: VoxelType]) {
        lock.lock()
        edits = savedEdits
        lock.unlock()
    }

    /// A full copy of every edit — used by SaveGame to persist the world.
    func allEdits() -> [BlockCoord: VoxelType] {
        lock.lock()
        defer { lock.unlock() }
        return edits
    }

    /// A snapshot of edits within an inclusive (x, z) column range, copied
    /// out under the lock once so a chunk build can then do plain, unlocked
    /// dictionary lookups per-voxel instead of locking per query.
    func snapshot(xRange: ClosedRange<Int>, zRange: ClosedRange<Int>) -> [BlockCoord: VoxelType] {
        lock.lock()
        defer { lock.unlock() }
        guard !edits.isEmpty else { return [:] }
        return edits.filter { xRange.contains($0.key.x) && zRange.contains($0.key.z) }
    }

    /// The min/max edited Y at a single (x, z) column, or nil if it has no
    /// edits — lets a caller that otherwise has an O(1) procedural answer
    /// (Renderer's groundHeight) skip the more expensive "actually figure out
    /// what's solid" scan entirely for the overwhelming majority of columns
    /// nobody has touched.
    func editedYRange(x: Int, z: Int) -> ClosedRange<Int>? {
        lock.lock()
        defer { lock.unlock() }
        var range: ClosedRange<Int>?
        for (coord, _) in edits where coord.x == x && coord.z == z {
            if let existing = range {
                range = min(existing.lowerBound, coord.y)...max(existing.upperBound, coord.y)
            } else {
                range = coord.y...coord.y
            }
        }
        return range
    }
}
