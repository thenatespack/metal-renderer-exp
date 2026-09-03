import simd

/// Blocky humanoid villager mesh — same box-list/rotate-by-yaw approach as
/// AnimalMesh, just one fixed body shape (no per-villager variants needed
/// for this version). Rebuilt fresh in world space every frame per villager,
/// same reasoning as AnimalMesh/PlayerModel: tiny vertex counts, not worth
/// caching.
enum VillagerMesh {
    private struct Box {
        let center: SIMD3<Float> // local offset from feet, before yaw rotation
        let size: SIMD3<Float>
        let color: SIMD3<Float>
    }

    private static let skin = SIMD3<Float>(0.85, 0.68, 0.55)
    private static let robe = SIMD3<Float>(0.45, 0.35, 0.60)
    private static let robeDark = SIMD3<Float>(0.36, 0.27, 0.50)

    // Head/face at the front — matching Camera's yaw convention (0 faces
    // -Z), same as Villager.update's forward vector.
    private static let boxes: [Box] = [
        Box(center: SIMD3(0, 1.30, 0), size: SIMD3(0.30, 0.30, 0.30), color: skin),      // head
        Box(center: SIMD3(0, 0.85, 0), size: SIMD3(0.46, 0.60, 0.30), color: robe),      // torso/robe
        Box(center: SIMD3(-0.15, 0.275, 0), size: SIMD3(0.16, 0.55, 0.20), color: robeDark), // left leg
        Box(center: SIMD3(0.15, 0.275, 0), size: SIMD3(0.16, 0.55, 0.20), color: robeDark),  // right leg
        Box(center: SIMD3(-0.33, 0.85, 0), size: SIMD3(0.14, 0.50, 0.16), color: robe),  // left arm
        Box(center: SIMD3(0.33, 0.85, 0), size: SIMD3(0.14, 0.50, 0.16), color: robe),   // right arm
    ]

    // Same corner layout/winding as AnimalMesh/PlayerModel's own.
    private static let faceNormals: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
    ]
    private static let faceCorners: [[Int]] = [
        [1, 2, 6, 5], [0, 4, 7, 3], [3, 7, 6, 2], [0, 1, 5, 4], [4, 5, 6, 7], [0, 3, 2, 1],
    ]

    /// `feetPosition`: world-space point at the ground under the villager.
    /// `yaw`: same convention as Camera.yaw (0 faces -Z).
    /// `walkBobPhase`: 0 while idle; accumulated time*speed while walking.
    static func buildMesh(feetPosition: SIMD3<Float>, yaw: Float, walkBobPhase: Float) -> (vertices: [Vertex], indices: [UInt32]) {
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(v.x * cosYaw - v.z * sinYaw, v.y, v.x * sinYaw + v.z * cosYaw)
        }

        let bob = abs(sin(walkBobPhase)) * 0.05
        let origin = feetPosition + SIMD3<Float>(0, bob, 0)

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
            let worldCorners = localCorners.map { rotate($0) + origin }

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
