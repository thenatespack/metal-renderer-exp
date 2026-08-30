import simd

/// A thin wireframe cube outline, rebuilt each frame around whichever block
/// the player is currently looking at — cheap enough (24 vertices) not to
/// bother caching, same reasoning as PlayerModel.
enum BlockHighlight {
    // Same 8-corner layout as VoxelMesher.cubeCorners.
    private static let corners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
    ]

    // The cube's 12 edges as corner-index pairs.
    private static let edges: [(Int, Int)] = [
        (0, 1), (1, 5), (5, 4), (4, 0),
        (3, 2), (2, 6), (6, 7), (7, 3),
        (0, 3), (1, 2), (5, 6), (4, 7),
    ]

    /// `blockOrigin`: the block's own min corner (its integer voxel coordinate).
    /// `inflate`: how far to push each corner out from the box's center, so
    /// the outline sits just outside the block's own faces instead of
    /// z-fighting with them.
    static func buildVertices(blockOrigin: SIMD3<Float>, color: SIMD3<Float>, inflate: Float = 0.008) -> [Vertex] {
        let center = SIMD3<Float>(0.5, 0.5, 0.5)
        let worldCorners = corners.map { corner -> SIMD3<Float> in
            let outward = normalize(corner - center)
            return blockOrigin + corner + outward * inflate
        }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(edges.count * 2)
        for (a, b) in edges {
            vertices.append(Vertex(position: worldCorners[a], normal: .zero, color: color))
            vertices.append(Vertex(position: worldCorners[b], normal: .zero, color: color))
        }
        return vertices
    }
}
