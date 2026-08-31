import Metal

struct ChunkCoord: Hashable {
    let x: Int
    let z: Int
}

struct ChunkGeometry {
    let vertexBuffer: MTLBuffer?
    let indexBuffer: MTLBuffer?
    let indexCount: Int
}

/// One streamed piece of terrain: `size` x `worldHeight` x `size` voxels,
/// generated and meshed on construction. Border columns (one step outside the
/// chunk on x/z) are resolved straight from TerrainGenerator rather than from
/// a neighbor Chunk, so chunks can be built in any order with no stitching step.
///
/// Water and leaves each get their own mesh + draw pass so they can animate
/// independently of static terrain (see Shaders.swift): water gently waves,
/// leaves gently sway in the wind. The opaque mesh treats both as
/// non-blocking (so a submerged lakebed's top face still renders through
/// water above it, and a trunk face behind leaves still renders through
/// them), while water/leaves cull normally against solids and each other so
/// they only ever draw their actually-exposed surface. Water's four side
/// faces are the one exception — always drawn against non-water — so a lake
/// shows a visible wall of depth at its shoreline instead of reading as a
/// bare floating plane.
final class Chunk {
    let coord: ChunkCoord
    let opaque: ChunkGeometry
    let foliage: ChunkGeometry
    let water: ChunkGeometry

    init(coord: ChunkCoord, size: Int, worldHeight: Int, generator: TerrainGenerator, blockEdits: BlockEdits, device: MTLDevice) {
        self.coord = coord

        let originX = coord.x * size
        let originZ = coord.z * size
        let tableSize = size + 2 // one column of border on each side

        var columnTable = [ColumnInfo]()
        columnTable.reserveCapacity(tableSize * tableSize)
        for lz in 0..<tableSize {
            for lx in 0..<tableSize {
                columnTable.append(generator.columnInfo(x: originX + lx - 1, z: originZ + lz - 1))
            }
        }

        // One locked read for the whole chunk build, covering both this
        // chunk's own voxels and the 1-column border used for neighbor face
        // culling — everything after this is a plain, unlocked dictionary
        // lookup per voxel. See BlockEdits.
        let localEdits = blockEdits.snapshot(
            xRange: (originX - 1)...(originX + size),
            zRange: (originZ - 1)...(originZ + size)
        )

        func voxelAt(_ x: Int, _ y: Int, _ z: Int) -> VoxelType {
            if y < 0 { return .stone }
            if y >= worldHeight { return .air }

            let worldX = originX + x
            let worldZ = originZ + z
            if let edited = localEdits[BlockCoord(x: worldX, y: y, z: worldZ)] {
                return edited
            }

            let info = columnTable[(x + 1) + (z + 1) * tableSize]
            if y > info.height {
                if y <= info.height + TerrainGenerator.treeSearchBand,
                   let tree = generator.treeBlock(x: worldX, y: y, z: worldZ) {
                    return tree
                }
                return y <= TerrainGenerator.seaLevel ? .water : .air
            }
            guard !generator.isCarved(x: worldX, y: y, z: worldZ, surfaceHeight: info.height) else { return .air }
            if y == info.height {
                return info.topBlock
            } else if y >= info.height - 3 {
                return info.subBlock
            } else {
                return .stone
            }
        }

        let (opaqueVertices, opaqueIndices) = VoxelMesher.buildMesh(
            originX: originX, originZ: originZ,
            sizeX: size, sizeY: worldHeight, sizeZ: size,
            voxelAt: voxelAt,
            isTarget: { $0.isSolid && $0 != .water && $0 != .leaves },
            isBlocking: { voxel, _ in voxel.isSolid && voxel != .water && voxel != .leaves }
        )
        self.opaque = Self.makeGeometry(vertices: opaqueVertices, indices: opaqueIndices, device: device)

        let (foliageVertices, foliageIndices) = VoxelMesher.buildMesh(
            originX: originX, originZ: originZ,
            sizeX: size, sizeY: worldHeight, sizeZ: size,
            voxelAt: voxelAt,
            isTarget: { $0 == .leaves },
            isBlocking: { voxel, _ in voxel.isSolid }
        )
        self.foliage = Self.makeGeometry(vertices: foliageVertices, indices: foliageIndices, device: device)

        let (waterVertices, waterIndices) = VoxelMesher.buildMesh(
            originX: originX, originZ: originZ,
            sizeX: size, sizeY: worldHeight, sizeZ: size,
            voxelAt: voxelAt,
            isTarget: { $0 == .water },
            isBlocking: { voxel, normal in normal.y != 0 ? voxel.isSolid : voxel == .water }
        )
        self.water = Self.makeGeometry(vertices: waterVertices, indices: waterIndices, device: device)
    }

    private static func makeGeometry(vertices: [Vertex], indices: [UInt32], device: MTLDevice) -> ChunkGeometry {
        guard !indices.isEmpty else {
            return ChunkGeometry(vertexBuffer: nil, indexBuffer: nil, indexCount: 0)
        }
        let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared)
        let indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared)
        return ChunkGeometry(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count)
    }
}
