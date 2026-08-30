import simd

/// A small spinning cube representing a block dropped by breaking it in
/// survival mode. Rebuilt fresh in world space each frame per active item —
/// same reasoning as PlayerModel/BlockHighlight: tiny vertex counts, not
/// worth a persistent buffer.
enum DroppedItemMesh {
    // Same corner/winding layout as VoxelMesher.cubeCorners + faces.
    private static let corners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
    ]
    private static let faceNormals: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
    ]
    private static let faceCorners: [[Int]] = [
        [1, 2, 6, 5], [0, 4, 7, 3], [3, 7, 6, 2], [0, 1, 5, 4], [4, 5, 6, 7], [0, 3, 2, 1],
    ]

    static func appendCube(
        center: SIMD3<Float>, size: Float, yaw: Float, color: SIMD3<Float>,
        into vertices: inout [Vertex], indices: inout [UInt32]
    ) {
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(v.x * cosYaw - v.z * sinYaw, v.y, v.x * sinYaw + v.z * cosYaw)
        }

        let localCorners = corners.map { ($0 - SIMD3<Float>(0.5, 0.5, 0.5)) * size }
        let worldCorners = localCorners.map { rotate($0) + center }

        for (normalIndex, faceIdx) in faceCorners.enumerated() {
            let normal = rotate(faceNormals[normalIndex])
            let start = UInt32(vertices.count)
            for corner in faceIdx {
                vertices.append(Vertex(position: worldCorners[corner], normal: normal, color: color))
            }
            indices.append(contentsOf: [start, start + 1, start + 2, start, start + 2, start + 3])
        }
    }
}
