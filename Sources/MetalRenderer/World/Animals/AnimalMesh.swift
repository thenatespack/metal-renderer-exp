import simd

/// Blocky per-species critter meshes — same box-list approach as PlayerModel
/// (a handful of cuboids, rotated by yaw and offset from a feet position),
/// just with a layout per AnimalType instead of one fixed humanoid. Rebuilt
/// fresh in world space every frame per animal, same reasoning as
/// PlayerModel/DroppedItemMesh: tiny vertex counts, not worth caching.
enum AnimalMesh {
    private struct Box {
        let center: SIMD3<Float> // local offset from feet, before yaw rotation
        let size: SIMD3<Float>
        let color: SIMD3<Float>
    }

    // Head/snout/ears sit at -z, matching Camera's yaw convention (0 faces
    // -Z) — see Animal.update's forward vector, which this has to agree
    // with or the animal walks backward relative to its own face.
    private static let pigPink = SIMD3<Float>(0.93, 0.62, 0.64)
    private static let pigPinkDark = SIMD3<Float>(0.78, 0.48, 0.52)
    private static let pigSnout = SIMD3<Float>(0.72, 0.42, 0.48)
    private static let pigBoxes: [Box] = [
        Box(center: SIMD3(0, 0.34, 0.02), size: SIMD3(0.56, 0.34, 0.32), color: pigPink),
        Box(center: SIMD3(0, 0.36, -0.34), size: SIMD3(0.28, 0.26, 0.26), color: pigPink),
        Box(center: SIMD3(0, 0.32, -0.49), size: SIMD3(0.16, 0.13, 0.09), color: pigSnout),
        Box(center: SIMD3(-0.10, 0.51, -0.30), size: SIMD3(0.09, 0.10, 0.05), color: pigPinkDark), // left ear
        Box(center: SIMD3(0.10, 0.51, -0.30), size: SIMD3(0.09, 0.10, 0.05), color: pigPinkDark),  // right ear
        Box(center: SIMD3(-0.18, 0.12, -0.11), size: SIMD3(0.11, 0.24, 0.11), color: pigPinkDark),
        Box(center: SIMD3(0.18, 0.12, -0.11), size: SIMD3(0.11, 0.24, 0.11), color: pigPinkDark),
        Box(center: SIMD3(-0.18, 0.12, 0.15), size: SIMD3(0.11, 0.24, 0.11), color: pigPinkDark),
        Box(center: SIMD3(0.18, 0.12, 0.15), size: SIMD3(0.11, 0.24, 0.11), color: pigPinkDark),
    ]

    private static let wool = SIMD3<Float>(0.90, 0.90, 0.87)
    private static let sheepDark = SIMD3<Float>(0.24, 0.21, 0.19)
    private static let sheepBoxes: [Box] = [
        Box(center: SIMD3(0, 0.50, 0.03), size: SIMD3(0.62, 0.42, 0.44), color: wool),
        Box(center: SIMD3(0, 0.40, -0.38), size: SIMD3(0.26, 0.24, 0.24), color: sheepDark), // head, poking out under the wool
        Box(center: SIMD3(-0.13, 0.45, -0.32), size: SIMD3(0.07, 0.06, 0.10), color: sheepDark), // left ear
        Box(center: SIMD3(0.13, 0.45, -0.32), size: SIMD3(0.07, 0.06, 0.10), color: sheepDark),  // right ear
        Box(center: SIMD3(0, 0.50, 0.28), size: SIMD3(0.12, 0.12, 0.10), color: wool),           // tail
        Box(center: SIMD3(-0.21, 0.14, -0.14), size: SIMD3(0.12, 0.30, 0.12), color: sheepDark),
        Box(center: SIMD3(0.21, 0.14, -0.14), size: SIMD3(0.12, 0.30, 0.12), color: sheepDark),
        Box(center: SIMD3(-0.21, 0.14, 0.16), size: SIMD3(0.12, 0.30, 0.12), color: sheepDark),
        Box(center: SIMD3(0.21, 0.14, 0.16), size: SIMD3(0.12, 0.30, 0.12), color: sheepDark),
    ]

    private static let feathers = SIMD3<Float>(0.95, 0.95, 0.90)
    private static let beakColor = SIMD3<Float>(0.90, 0.55, 0.12)
    private static let combColor = SIMD3<Float>(0.75, 0.15, 0.12)
    private static let chickenBoxes: [Box] = [
        Box(center: SIMD3(0, 0.32, 0), size: SIMD3(0.34, 0.30, 0.28), color: feathers),
        // Head/beak/comb at -z — see pig's comment above.
        Box(center: SIMD3(0, 0.50, -0.16), size: SIMD3(0.16, 0.16, 0.16), color: feathers),
        Box(center: SIMD3(0, 0.47, -0.28), size: SIMD3(0.08, 0.05, 0.09), color: beakColor),
        Box(center: SIMD3(0, 0.60, -0.16), size: SIMD3(0.06, 0.06, 0.10), color: combColor),
        Box(center: SIMD3(-0.07, 0.13, 0), size: SIMD3(0.06, 0.26, 0.06), color: beakColor),
        Box(center: SIMD3(0.07, 0.13, 0), size: SIMD3(0.06, 0.26, 0.06), color: beakColor),
    ]

    private static func boxes(for type: AnimalType) -> [Box] {
        switch type {
        case .pig: return pigBoxes
        case .sheep: return sheepBoxes
        case .chicken: return chickenBoxes
        }
    }

    // Same corner layout/winding as PlayerModel's — see its own comment.
    private static let faceNormals: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
    ]
    private static let faceCorners: [[Int]] = [
        [1, 2, 6, 5], [0, 4, 7, 3], [3, 7, 6, 2], [0, 1, 5, 4], [4, 5, 6, 7], [0, 3, 2, 1],
    ]

    /// `feetPosition`: world-space point at the ground under the animal.
    /// `yaw`: same convention as Camera.yaw (0 faces -Z).
    /// `walkBobPhase`: 0 while idle; accumulated time*speed while walking —
    /// bounces the whole critter slightly to read as mid-stride, cheaper
    /// than actually articulating each leg for something this small on screen.
    /// `hitFlash`: 0...1, blends every box toward red — see Animal.hitFlashTimer.
    static func buildMesh(type: AnimalType, feetPosition: SIMD3<Float>, yaw: Float, walkBobPhase: Float, hitFlash: Float = 0) -> (vertices: [Vertex], indices: [UInt32]) {
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(v.x * cosYaw - v.z * sinYaw, v.y, v.x * sinYaw + v.z * cosYaw)
        }

        let bob = abs(sin(walkBobPhase)) * 0.05
        let origin = feetPosition + SIMD3<Float>(0, bob, 0)

        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        let flashColor = SIMD3<Float>(0.9, 0.15, 0.12)
        for box in boxes(for: type) {
            let color = hitFlash > 0 ? box.color * (1 - hitFlash) + flashColor * hitFlash : box.color
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
                    vertices.append(Vertex(position: worldCorners[corner], normal: normal, color: color))
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
