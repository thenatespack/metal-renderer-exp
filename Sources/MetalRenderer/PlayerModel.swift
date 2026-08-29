import simd

/// A tiny blocky humanoid (head/torso/arms/legs) — only relevant in
/// third-person, since in first-person the camera IS the player. Rebuilt
/// fresh in world space every frame from the player's feet position and
/// facing; at ~144 vertices that's cheap enough not to bother caching.
enum PlayerModel {
    private struct Box {
        let center: SIMD3<Float> // local offset from feet, before yaw rotation
        let size: SIMD3<Float>
        let color: SIMD3<Float>
    }

    private static let skinColor = SIMD3<Float>(0.85, 0.65, 0.50)
    private static let shirtColor = SIMD3<Float>(0.25, 0.45, 0.75)
    private static let pantsColor = SIMD3<Float>(0.20, 0.20, 0.30)

    private static let boxes: [Box] = [
        Box(center: SIMD3(0, 1.55, 0), size: SIMD3(0.5, 0.5, 0.5), color: skinColor),         // head
        Box(center: SIMD3(0, 1.05, 0), size: SIMD3(0.5, 0.6, 0.3), color: shirtColor),        // torso
        Box(center: SIMD3(-0.42, 1.05, 0), size: SIMD3(0.18, 0.6, 0.18), color: shirtColor),  // left arm
        Box(center: SIMD3(0.42, 1.05, 0), size: SIMD3(0.18, 0.6, 0.18), color: shirtColor),   // right arm
        Box(center: SIMD3(-0.15, 0.4, 0), size: SIMD3(0.2, 0.8, 0.2), color: pantsColor),     // left leg
        Box(center: SIMD3(0.15, 0.4, 0), size: SIMD3(0.2, 0.8, 0.2), color: pantsColor),      // right leg
    ]

    // Same corner layout/winding as VoxelMesher's cubeCorners + faces, just
    // centered at the box's own center instead of starting at its min corner.
    private static let faceNormals: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
    ]
    private static let faceCorners: [[Int]] = [
        [1, 2, 6, 5], [0, 4, 7, 3], [3, 7, 6, 2], [0, 1, 5, 4], [4, 5, 6, 7], [0, 3, 2, 1],
    ]

    /// `feetPosition`: world-space point at the ground under the player.
    /// `yaw`: same convention as Camera.yaw (0 faces -Z).
    static func buildMesh(feetPosition: SIMD3<Float>, yaw: Float) -> (vertices: [Vertex], indices: [UInt32]) {
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)

        // Rotate about Y to match Camera.front's convention (yaw 0 -> -Z).
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(v.x * cosYaw - v.z * sinYaw, v.y, v.x * sinYaw + v.z * cosYaw)
        }

        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        for box in boxes {
            let half = box.size * 0.5
            let localCorners: [SIMD3<Float>] = [
                box.center + SIMD3(-half.x, -half.y, -half.z),
                box.center + SIMD3(half.x, -half.y, -half.z),
                box.center + SIMD3(half.x, half.y, -half.z),
                box.center + SIMD3(-half.x, half.y, -half.z),
                box.center + SIMD3(-half.x, -half.y, half.z),
                box.center + SIMD3(half.x, -half.y, half.z),
                box.center + SIMD3(half.x, half.y, half.z),
                box.center + SIMD3(-half.x, half.y, half.z),
            ]
            let worldCorners = localCorners.map { rotate($0) + feetPosition }

            for (normalIndex, corners) in faceCorners.enumerated() {
                let normal = rotate(faceNormals[normalIndex])
                let startIndex = UInt32(vertices.count)
                for corner in corners {
                    vertices.append(Vertex(position: worldCorners[corner], normal: normal, color: box.color))
                }
                indices.append(contentsOf: [
                    startIndex, startIndex + 1, startIndex + 2,
                    startIndex, startIndex + 2, startIndex + 3,
                ])
            }
        }

        return (vertices, indices)
    }
}
