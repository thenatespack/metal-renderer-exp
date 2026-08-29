import MetalKit
import simd
import QuartzCore

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let foliagePipelineState: MTLRenderPipelineState
    private let waterPipelineState: MTLRenderPipelineState
    private let waterDepthState: MTLDepthStencilState
    private let highlightPipelineState: MTLRenderPipelineState

    private let chunkManager: ChunkManager

    private var uniformBuffers: [MTLBuffer] = []
    private let maxBuffersInFlight = 3
    private var currentBufferIndex = 0
    private let inFlightSemaphore = DispatchSemaphore(value: 3)

    private let inputController: InputController
    let camera: Camera
    private let playerController: PlayerController
    private let isSolidAt: (Float, Float, Float) -> Bool
    private let waterSurfaceHeight: (Float, Float) -> Float?
    private let blockEdits = BlockEdits()
    let hotbar = Hotbar()
    private var lastFrameTime = CACurrentMediaTime()
    private var elapsedTime: Float = 0

    var isPaused = false
    /// Called once a second (see logBenchmark) with a formatted multi-line
    /// stats string, for the debug overlay (H) to display.
    var onStatsUpdate: ((String) -> Void)?
    /// Called every frame with the hotbar's current selected index, for
    /// HotbarView to highlight.
    var onHotbarSelectionChanged: ((Int) -> Void)?

    private var aspectRatio: Float = 1

    // Rolling 1-second window, logged to stdout — see draw(in:).
    private var benchWindowSeconds: Float = 0
    private var benchFrameCount = 0
    private var benchFrameMsSum: Double = 0
    private var benchFrameMsMax: Double = 0

    private let fogColor = SIMD3<Float>(0.53, 0.81, 0.92)
    // Tuned to roughly mask the chunk load/unload boundary (loadRadius * chunkSize)
    // in ChunkManager, so streaming pop-in happens mostly hidden in fog.
    private let fogDistance: Float = 170

    // Swapped in for fogColor/fogDistance whenever the camera's own eye
    // position is underwater — reuses the existing fog machinery (every
    // fragment shader already mixes toward uniforms.fogColor at
    // uniforms.fogDistance) rather than needing a separate underwater shader
    // path, so the whole view reads as murky/short-range without any
    // per-material special-casing.
    private let underwaterFogColor = SIMD3<Float>(0.05, 0.22, 0.40)
    private let underwaterFogDistance: Float = 18
    private let underwaterHysteresis: Float = 0.2
    private var isCameraUnderwater = false
    private let farPlane: Float = 400

    init(device: MTLDevice, inputController: InputController) {
        self.device = device
        self.inputController = inputController

        guard let queue = device.makeCommandQueue() else {
            fatalError("Could not create command queue")
        }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            fatalError("Could not compile Metal shader library: \(error)")
        }
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float3
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        func makePipelineState(vertexFunctionName: String, fragmentFunctionName: String, blended: Bool) -> MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertexFunctionName),
                  let fragmentFunction = library.makeFunction(name: fragmentFunctionName) else {
                fatalError("Could not find shader functions \(vertexFunctionName)/\(fragmentFunctionName)")
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            let colorAttachment = pipelineDescriptor.colorAttachments[0]!
            colorAttachment.pixelFormat = .bgra8Unorm
            if blended {
                colorAttachment.isBlendingEnabled = true
                colorAttachment.rgbBlendOperation = .add
                colorAttachment.alphaBlendOperation = .add
                colorAttachment.sourceRGBBlendFactor = .sourceAlpha
                colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                colorAttachment.sourceAlphaBlendFactor = .sourceAlpha
                colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }

            do {
                return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                fatalError("Could not create render pipeline state: \(error)")
            }
        }

        self.pipelineState = makePipelineState(vertexFunctionName: "vertex_main", fragmentFunctionName: "fragment_main", blended: false)
        self.foliagePipelineState = makePipelineState(vertexFunctionName: "vertex_foliage", fragmentFunctionName: "fragment_foliage", blended: false)
        self.waterPipelineState = makePipelineState(vertexFunctionName: "vertex_water", fragmentFunctionName: "fragment_water", blended: true)
        self.highlightPipelineState = makePipelineState(vertexFunctionName: "vertex_highlight", fragmentFunctionName: "fragment_highlight", blended: false)

        func makeDepthState(writesDepth: Bool) -> MTLDepthStencilState {
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = writesDepth
            guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
                fatalError("Could not create depth stencil state")
            }
            return state
        }

        // Water doesn't write depth: it still reads/tests against the opaque
        // pass's depth (so it's correctly hidden behind terrain in front of it),
        // but not writing means it never occludes anything drawn after it, which
        // matters once there's more than one translucent surface in view.
        self.depthState = makeDepthState(writesDepth: true)
        self.waterDepthState = makeDepthState(writesDepth: false)

        let worldHeight = 48
        let chunkSize = 16
        let seed = UInt64.random(in: 0...UInt64.max)
        let generator = TerrainGenerator(seed: seed, worldHeight: worldHeight)
        let blockEdits = self.blockEdits
        self.chunkManager = ChunkManager(device: device, generator: generator, blockEdits: blockEdits, chunkSize: chunkSize, worldHeight: worldHeight)

        for _ in 0..<maxBuffersInFlight {
            guard let buffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared) else {
                fatalError("Could not create uniform buffer")
            }
            uniformBuffers.append(buffer)
        }

        // The single source of truth for "what's actually at this world
        // coordinate": a player edit if there is one, else whatever
        // TerrainGenerator would put there. Every collision/raycast query
        // below is built on this, so breaking/placing a block is always
        // immediately reflected in physics, not just in the mesh.
        func blockAt(_ x: Int, _ y: Int, _ z: Int) -> VoxelType {
            if let edited = blockEdits.get(BlockCoord(x: x, y: y, z: z)) {
                return edited
            }
            return generator.proceduralBlock(x: x, y: y, z: z, worldHeight: worldHeight)
        }

        // The real solid terrain surface — no sea-level clamping, since
        // PlayerController's swimming physics needs to know how deep a
        // lakebed actually is, not just that it's underwater. +1 because a
        // solid voxel at index `height` spans world y in [height, height+1]
        // (see VoxelMesher/cubeCorners) — the walkable surface is its top
        // face, not the voxel's own coordinate.
        //
        // Fast path when nobody's edited this column: the O(1) procedural
        // answer, same as before edits existed at all. Only a column that
        // actually has edits pays for scanning down from the higher of the
        // procedural height or the highest edit to find the true topmost
        // solid block — bounded by how far the player has actually built,
        // not by worldHeight.
        let groundHeight: (Float, Float) -> Float = { x, z in
            let ix = Int(x.rounded(.down))
            let iz = Int(z.rounded(.down))
            let proceduralHeight = generator.columnInfo(x: ix, z: iz).height
            guard let editRange = blockEdits.editedYRange(x: ix, z: iz) else {
                return Float(proceduralHeight + 1)
            }
            let top = max(proceduralHeight, editRange.upperBound) + 1
            let bottom = min(proceduralHeight, editRange.lowerBound) - 1
            var y = top
            while y >= bottom {
                if blockAt(ix, y, iz).isSolid { return Float(y + 1) }
                y -= 1
            }
            return Float(bottom + 1)
        }

        // The water surface height at this column, or nil if it's dry. A
        // column is wet only when its terrain sits strictly below sea level —
        // matching the actual water-fill condition in Chunk.voxelAt, not an
        // off-by-one loose version of it. Water itself isn't editable, so
        // this stays purely procedural.
        let waterSurfaceHeight: (Float, Float) -> Float? = { x, z in
            let info = generator.columnInfo(x: Int(x.rounded(.down)), z: Int(z.rounded(.down)))
            return info.height < TerrainGenerator.seaLevel ? Float(TerrainGenerator.seaLevel + 1) : nil
        }

        // Ground height alone doesn't see vertical obstacles that don't
        // affect terrain elevation — a tree, or a block the player placed at
        // head height. This checks separately whether anything solid
        // occupies the player's own body height above this column's ground.
        // Only that band, not all the way up — something well above head
        // height shouldn't block walking through a clear gap underneath it.
        let playerBodyHeightBlocks = 2 // matches PlayerController.eyeHeight (1.75), rounded up
        let isObstructed: (Float, Float) -> Bool = { x, z in
            let ix = Int(x.rounded(.down))
            let iz = Int(z.rounded(.down))
            let surfaceTop = Int(groundHeight(x, z))
            for y in surfaceTop..<(surfaceTop + playerBodyHeightBlocks) {
                if blockAt(ix, y, iz).isSolid { return true }
            }
            return false
        }

        // General point-in-solid query, used by the third-person camera to
        // stop short of clipping through terrain/trees/placed blocks behind
        // the player, and by the break/place raycast to find a target.
        let isSolidAt: (Float, Float, Float) -> Bool = { x, y, z in
            blockAt(Int(x.rounded(.down)), Int(y.rounded(.down)), Int(z.rounded(.down))).isSolid
        }

        let spawnHeight = groundHeight(8, 8)
        let camera = Camera(position: SIMD3<Float>(8, spawnHeight, 8), yaw: 0, pitch: 0)
        self.camera = camera
        let playerController = PlayerController(
            camera: camera,
            groundHeight: groundHeight,
            waterSurfaceHeight: waterSurfaceHeight,
            isObstructed: isObstructed,
            isSolidAt: isSolidAt
        )
        camera.position.y = spawnHeight + playerController.eyeHeight
        self.playerController = playerController
        self.isSolidAt = isSolidAt
        self.waterSurfaceHeight = waterSurfaceHeight

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspectRatio = size.width > 0 && size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        inFlightSemaphore.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        let now = CACurrentMediaTime()
        let deltaTime = Float(now - lastFrameTime)
        lastFrameTime = now
        elapsedTime += deltaTime
        // Chunk streaming keeps running even while paused, so the world
        // around spawn is already loaded by the time the player hits Play —
        // only the player's own movement/physics freezes.
        if !isPaused {
            playerController.update(input: inputController, deltaTime: deltaTime)
            hotbar.update(input: inputController)
        }
        onHotbarSelectionChanged?(hotbar.selectedIndex)
        chunkManager.update(around: camera.position)
        logBenchmark(deltaTime: deltaTime)

        currentBufferIndex = (currentBufferIndex + 1) % maxBuffersInFlight
        let uniformBuffer = uniformBuffers[currentBufferIndex]

        let eyePosition = camera.eyePosition
        // Hysteresis, not a single hard threshold: the water surface itself
        // bobs (see vertex_water's wave) and the camera bobs a little too, so
        // a flat "eye.y < waterTop" flips every frame near the boundary —
        // fog/clear color strobing between sky and underwater each frame.
        // Requiring a full crossing of a small dead-band before flipping
        // state fixes that without needing to touch the wave itself.
        if let waterTop = waterSurfaceHeight(eyePosition.x, eyePosition.z) {
            if isCameraUnderwater {
                isCameraUnderwater = eyePosition.y < waterTop + underwaterHysteresis
            } else {
                isCameraUnderwater = eyePosition.y < waterTop - underwaterHysteresis
            }
        } else {
            isCameraUnderwater = false
        }
        let currentFogColor = isCameraUnderwater ? underwaterFogColor : fogColor
        let currentFogDistance = isCameraUnderwater ? underwaterFogDistance : fogDistance

        let modelMatrix = matrix_identity_float4x4
        let projectionMatrix = Math.perspective(fovyRadians: .pi / 4, aspect: aspectRatio, near: 0.1, far: farPlane)
        let viewProjectionMatrix = projectionMatrix * camera.viewMatrix

        var uniforms = Uniforms(
            modelMatrix: modelMatrix,
            viewProjectionMatrix: viewProjectionMatrix,
            normalMatrix: matrix_identity_float3x3,
            lightDirection: normalize(SIMD3<Float>(-0.4, -1, -0.3)),
            cameraPosition: eyePosition,
            fogColor: currentFogColor,
            fogDistance: currentFogDistance,
            time: elapsedTime
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            return
        }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(currentFogColor.x), green: Double(currentFogColor.y), blue: Double(currentFogColor.z), alpha: 1.0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            inFlightSemaphore.signal()
            return
        }

        // Every voxel face is wound so front == outward normal, so hardware culling
        // is safe here and drops the ~half of exposed faces facing away each frame.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        for chunk in chunkManager.loadedChunks.values {
            draw(chunk.opaque, with: encoder)
        }

        // Only relevant in third person — in first person the camera IS the
        // player, so there's nothing to draw.
        if camera.isThirdPerson {
            drawPlayerModel(with: encoder)
        }

        // Foliage: same opaque depth state as terrain (it writes depth, no
        // blending), just a different vertex function for the wind sway.
        encoder.setRenderPipelineState(foliagePipelineState)
        for chunk in chunkManager.loadedChunks.values {
            draw(chunk.foliage, with: encoder)
        }

        if let hit = raycastTargetBlock() {
            drawBlockHighlight(around: hit.block, with: encoder)
        }

        // Water pass second, over the now depth-written opaque scene, blended
        // and without writing depth of its own. Culling off: the surface
        // needs to render as a visible ceiling from underneath, and the
        // shoreline/lakebed depth walls need to read as an enclosure when
        // swimming inside one, not just show their single outward face.
        // fragment_water flips the normal on back-facing fragments, so both
        // sides are correctly lit either way instead of a wall's backside
        // rendering as an unlit dark sliver.
        encoder.setRenderPipelineState(waterPipelineState)
        encoder.setDepthStencilState(waterDepthState)
        encoder.setCullMode(.none)
        for chunk in chunkManager.loadedChunks.values {
            draw(chunk.water, with: encoder)
        }
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func logBenchmark(deltaTime: Float) {
        benchFrameCount += 1
        let frameMs = Double(deltaTime) * 1000
        benchFrameMsSum += frameMs
        benchFrameMsMax = max(benchFrameMsMax, frameMs)
        benchWindowSeconds += deltaTime

        guard benchWindowSeconds >= 1 else { return }

        let fps = Double(benchFrameCount) / Double(benchWindowSeconds)
        let avgMs = benchFrameMsSum / Double(benchFrameCount)
        print(String(
            format: "[bench] fps=%.1f avgFrameMs=%.2f maxFrameMs=%.2f loadedChunks=%d pending=%d triangles=%d chunkBuilds=%d avgChunkBuildMs=%.2f pos=(%.2f,%.2f,%.2f) grounded=%d swimming=%d",
            fps, avgMs, benchFrameMsMax,
            chunkManager.loadedChunks.count, chunkManager.pendingChunkCount, chunkManager.totalTriangleCount,
            chunkManager.totalChunksBuilt, chunkManager.averageChunkBuildMs,
            camera.position.x, camera.position.y, camera.position.z,
            playerController.isGrounded ? 1 : 0,
            playerController.isSwimming ? 1 : 0
        ))

        let posText = String(format: "%.1f, %.1f, %.1f", camera.position.x, camera.position.y, camera.position.z)
        let statsText = """
        FPS: \(Int(fps.rounded())) (\(String(format: "%.1f", avgMs)) ms)
        Pos: \(posText)
        Grounded: \(playerController.isGrounded ? "yes" : "no")   Swimming: \(playerController.isSwimming ? "yes" : "no")
        Third-person: \(camera.isThirdPerson ? "yes" : "no")
        Chunks: \(chunkManager.loadedChunks.count) loaded, \(chunkManager.pendingChunkCount) pending
        Triangles: \(chunkManager.totalTriangleCount)
        """
        onStatsUpdate?(statsText)

        benchWindowSeconds = 0
        benchFrameCount = 0
        benchFrameMsSum = 0
        benchFrameMsMax = 0
    }

    /// Settings-menu hook: keeps unloadRadius a couple chunks past loadRadius
    /// (the hysteresis gap ChunkManager already relies on to avoid thrashing
    /// at the boundary) rather than letting the two drift out of that ratio.
    func setRenderDistance(_ chunks: Int) {
        chunkManager.loadRadius = chunks
        chunkManager.unloadRadius = chunks + 2
    }

    private let highlightReach: Float = 6
    private let highlightStep: Float = 0.08

    private struct RaycastHit {
        let block: SIMD3<Int>        // the solid block hit — what breaking removes
        let placeAt: SIMD3<Int>?     // the empty cell just before it — where placing goes; nil if the ray started inside something solid
    }

    /// Marches from the player's own position (not the third-person camera —
    /// the reticle always reflects what the player is facing) along their
    /// look direction, up to `highlightReach`. Tracks the last empty cell
    /// visited before the hit, which is standard-resolution face detection:
    /// at this step size it's always the specific face that got hit, without
    /// needing to compute an actual surface normal.
    private func raycastTargetBlock() -> RaycastHit? {
        let origin = camera.position
        let direction = camera.front
        var traveled: Float = highlightStep
        var lastEmpty: SIMD3<Int>?
        while traveled < highlightReach {
            let sample = origin + direction * traveled
            let blockCoord = SIMD3<Int>(Int(sample.x.rounded(.down)), Int(sample.y.rounded(.down)), Int(sample.z.rounded(.down)))
            if isSolidAt(sample.x, sample.y, sample.z) {
                return RaycastHit(block: blockCoord, placeAt: lastEmpty)
            }
            lastEmpty = blockCoord
            traveled += highlightStep
        }
        return nil
    }

    /// Left click: removes whatever block the player is looking at.
    func breakTargetedBlock() {
        guard !isPaused, let hit = raycastTargetBlock() else { return }
        blockEdits.set(BlockCoord(hit.block), to: .air)
        chunkManager.rebuildAffectedChunks(byEditAt: hit.block)
    }

    /// Right click: places the hotbar's selected block into the empty cell
    /// adjacent to whatever face the player is looking at.
    func placeBlock() {
        guard !isPaused, let hit = raycastTargetBlock(), let placeAt = hit.placeAt else { return }

        // Don't let the player wall themselves in.
        let playerColumnX = Int(camera.position.x.rounded(.down))
        let playerColumnZ = Int(camera.position.z.rounded(.down))
        let feetY = Int((camera.position.y - playerController.eyeHeight).rounded(.down))
        let headY = Int(camera.position.y.rounded(.down))
        if placeAt.x == playerColumnX, placeAt.z == playerColumnZ, placeAt.y >= feetY, placeAt.y <= headY {
            return
        }

        blockEdits.set(BlockCoord(placeAt), to: hotbar.selectedType)
        chunkManager.rebuildAffectedChunks(byEditAt: placeAt)
    }

    // Rebuilt fresh every frame around whatever block is targeted (see
    // BlockHighlight) — trivially cheap (24 vertices), so no need to cache.
    private func drawBlockHighlight(around block: SIMD3<Int>, with encoder: MTLRenderCommandEncoder) {
        let origin = SIMD3<Float>(Float(block.x), Float(block.y), Float(block.z))
        let vertices = BlockHighlight.buildVertices(blockOrigin: origin, color: SIMD3<Float>(0.05, 0.05, 0.05))
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared) else {
            return
        }
        encoder.setRenderPipelineState(highlightPipelineState)
        encoder.setDepthStencilState(waterDepthState) // test-but-don't-write, shared with the water pass
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
    }

    // Rebuilt fresh every frame in world space (see PlayerModel) — small
    // enough (~144 vertices) that a fresh MTLBuffer per frame is simpler than
    // maintaining a persistent one, and costs nothing when not third-person
    // since this is only called in that branch.
    private func drawPlayerModel(with encoder: MTLRenderCommandEncoder) {
        let feetPosition = camera.position - SIMD3<Float>(0, playerController.eyeHeight, 0)
        let (vertices, indices) = PlayerModel.buildMesh(feetPosition: feetPosition, yaw: camera.yaw)
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared) else {
            return
        }
        draw(ChunkGeometry(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count), with: encoder)
    }

    private func draw(_ geometry: ChunkGeometry, with encoder: MTLRenderCommandEncoder) {
        guard let vertexBuffer = geometry.vertexBuffer, let indexBuffer = geometry.indexBuffer, geometry.indexCount > 0 else { return }
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle,
                                       indexCount: geometry.indexCount,
                                       indexType: .uint32,
                                       indexBuffer: indexBuffer,
                                       indexBufferOffset: 0)
    }
}
