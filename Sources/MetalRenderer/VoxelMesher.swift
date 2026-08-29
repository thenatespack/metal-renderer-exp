import simd

/// Builds a triangle mesh from a VoxelWorld using culled-face meshing: for every
/// solid voxel, a face is only emitted where the neighbor across that face is air.
/// Faces fully surrounded by other solid voxels (the bulk of a filled terrain
/// column) never generate geometry at all, which is the main win over naively
/// drawing a cube per voxel. Each emitted face is also wound so its front side
/// matches its outward normal, which lets the renderer keep hardware back-face
/// culling on to drop the ~half of exposed faces pointing away from the camera
/// on any given frame.
enum VoxelMesher {
    private struct Face {
        let normal: SIMD3<Int>
        // Local unit-cube corner indices, ordered so cross(b-a, c-a) == normal.
        let corners: [Int]
    }

    // Unit cube corners, 0..7, at (x,y,z) in {0,1}^3.
    private static let cubeCorners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
    ]

    private static let faces: [Face] = [
        Face(normal: SIMD3(1, 0, 0), corners: [1, 2, 6, 5]),
        Face(normal: SIMD3(-1, 0, 0), corners: [0, 4, 7, 3]),
        Face(normal: SIMD3(0, 1, 0), corners: [3, 7, 6, 2]),
        Face(normal: SIMD3(0, -1, 0), corners: [0, 1, 5, 4]),
        Face(normal: SIMD3(0, 0, 1), corners: [4, 5, 6, 7]),
        Face(normal: SIMD3(0, 0, -1), corners: [0, 3, 2, 1]),
    ]

    /// Meshes a `sizeX` x `sizeY` x `sizeZ` block of local coordinates (0..<size in
    /// each axis), placing vertices in world space at `(originX + x, y, originZ + z)`.
    /// `voxelAt` is queried for local coordinates one step outside that range too
    /// (-1 or size), so it must be able to answer for a chunk's border — see Chunk.
    ///
    /// `isTarget` picks which voxel types this call generates geometry for, and
    /// `isBlocking` picks which neighboring types are solid enough to cull a face
    /// against — given the face's own normal, so a caller can treat directions
    /// differently. Opaque terrain blocks the same way on every face. Water
    /// doesn't (see Chunk): top/bottom still cull against any solid (so a
    /// lakebed's top face renders through transparent water above it, and water
    /// doesn't draw a face flush against the ground it sits on), but the four
    /// side faces only cull against other water, so a lake actually shows a
    /// visible wall of depth at its shoreline instead of reading as a bare
    /// floating plane.
    static func buildMesh(
        originX: Int, originZ: Int,
        sizeX: Int, sizeY: Int, sizeZ: Int,
        voxelAt: (_ x: Int, _ y: Int, _ z: Int) -> VoxelType,
        isTarget: (VoxelType) -> Bool,
        isBlocking: (VoxelType, SIMD3<Int>) -> Bool
    ) -> (vertices: [Vertex], indices: [UInt32]) {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX {
                    let voxel = voxelAt(x, y, z)
                    guard isTarget(voxel) else { continue }

                    let color = voxel.color
                    let base = SIMD3<Float>(Float(originX + x), Float(y), Float(originZ + z))

                    for face in faces {
                        let nx = x + face.normal.x
                        let ny = y + face.normal.y
                        let nz = z + face.normal.z
                        guard !isBlocking(voxelAt(nx, ny, nz), face.normal) else { continue }

                        let startIndex = UInt32(vertices.count)
                        let normal = SIMD3<Float>(Float(face.normal.x), Float(face.normal.y), Float(face.normal.z))

                        for corner in face.corners {
                            vertices.append(Vertex(position: base + cubeCorners[corner], normal: normal, color: color))
                        }

                        indices.append(contentsOf: [
                            startIndex, startIndex + 1, startIndex + 2,
                            startIndex, startIndex + 2, startIndex + 3,
                        ])
                    }
                }
            }
        }

        return (vertices, indices)
    }
}
