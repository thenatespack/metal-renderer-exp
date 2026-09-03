import MetalKit
import simd
import QuartzCore
import Foundation

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let foliagePipelineState: MTLRenderPipelineState
    private let waterPipelineState: MTLRenderPipelineState
    private let waterDepthState: MTLDepthStencilState
    private let highlightPipelineState: MTLRenderPipelineState
    private let postProcessPipelineState: MTLRenderPipelineState

    // Scene is rendered opaque/foliage/water/highlight into these offscreen
    // textures first, then a second full-screen pass (fragment_post) samples
    // sceneColorTexture into the drawable — this is what makes both the post
    // effect and the resolution scale possible: the offscreen textures can be
    // smaller than the drawable and still get stretched to fill it. Sized in
    // rebuildOffscreenTextures, driven off drawableSizeWillChange and
    // setResolutionScale.
    private var sceneColorTexture: MTLTexture?
    private var sceneDepthTexture: MTLTexture?
    private var currentDrawableSize: CGSize = .zero
    private var resolutionScale: Float = 1.0
    private(set) var postEffect: PostEffect = .none

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
    private let blockAt: (Int, Int, Int) -> VoxelType
    private let groundHeight: (Float, Float) -> Float
    private let animalManager: AnimalManager
    private let villagerManager: VillagerManager
    // Stateless/pure — see TerrainGenerator's own doc comment — so MapView's
    // one-time snapshot (see terrainColor) can call it freely off to the side
    // of the normal chunk-building path.
    private let terrainGenerator: TerrainGenerator
    private let villageGenerator: VillageGenerator
    private let blockEdits = BlockEdits()
    private let worldID: UUID
    // Serial so overlapping saves (rapid-fire breaking/placing) don't race
    // each other writing the same file — see persistSave/saveNow.
    private let saveQueue = DispatchQueue(label: "com.metalrenderer.save", qos: .utility)
    let hotbar: Hotbar
    private(set) var gameMode: GameMode = .creative
    private var lastFrameTime = CACurrentMediaTime()
    private var elapsedTime: Float = 0

    let playerVitals: PlayerVitals
    /// Where the player respawns on death — the same spawn point used at
    /// world creation, not wherever they last were.
    private let spawnPosition: SIMD3<Float>
    // Only actually hits disk when health/hunger changed since the last
    // write (see updatePlayerVitals) — every-frame equality checks are far
    // cheaper than every-frame disk writes.
    private var lastPersistedHealth: Int
    private var lastPersistedHunger: Int
    /// Recomputed every frame (see draw(in:)) by scanning near the player via
    /// blockAt — cheap, and matches isCameraUnderwater/daylightFactor's own
    /// per-frame-recompute style rather than caching off an edit event.
    private(set) var isNearCraftingTable = false
    private static let craftingTableSearchRadius = 3

    // Survival breaking: which block (if any) is currently being chipped
    // away, and how far along. Reset whenever the target changes, the mouse
    // is released, or the mode isn't survival — see updateSurvivalBreaking.
    private var breakingTarget: SIMD3<Int>?
    private var breakingProgress: Float = 0

    private struct DroppedItem {
        let type: VoxelType
        var position: SIMD3<Float>
        var verticalVelocity: Float = 0
        let spawnTime: CFTimeInterval
    }
    private var droppedItems: [DroppedItem] = []
    private let itemPickupRadius: Float = 1.5
    private let itemDespawnSeconds: CFTimeInterval = 120
    // Matches PlayerController.gravity so items fall at the same rate the
    // player does, for a consistent feel.
    private let droppedItemGravity: Float = 22
    private let droppedItemSize: Float = 0.3

    var isPaused = false
    /// Called once a second (see logBenchmark) with a formatted multi-line
    /// stats string, for the debug overlay (H) to display.
    var onStatsUpdate: ((String) -> Void)?
    /// Called every frame with the hotbar's current slots and selected
    /// index, for HotbarView to display.
    var onHotbarChanged: (([HotbarSlot], Int) -> Void)?
    /// Called every frame with survival break progress (0 when not
    /// breaking), for BreakProgressView to display.
    var onBreakProgressChanged: ((Float) -> Void)?
    /// Called every frame with deltaTime, before input is consumed — lets
    /// AppDelegate drive GameControllerManager's per-frame stick polling
    /// without Renderer needing to import GameController/AppKit itself.
    var onFrameTick: ((Float) -> Void)?
    /// Called with a short message whenever a villager trade succeeds or
    /// fails (see tradeWithTargetedVillager), for ToastView to display.
    var onToastMessage: ((String) -> Void)?
    /// Called every frame with (health, maxHealth, hunger, maxHunger), for
    /// VitalsView to display.
    var onVitalsChanged: ((Int, Int, Int, Int) -> Void)?

    private var aspectRatio: Float = 1

    // Rolling 1-second window, logged to stdout — see draw(in:).
    private var benchWindowSeconds: Float = 0
    private var benchFrameCount = 0
    private var benchFrameMsSum: Double = 0
    private var benchFrameMsMax: Double = 0
    // CPU% is derived from the change in cumulative process CPU time across
    // this same 1-second window (see logBenchmark) — this is the baseline
    // that gets diffed against each time. GPU ms is instead updated as each
    // frame's command buffer actually completes (see draw(in:)'s completion
    // handler), independent of the 1-second window.
    private var lastCPUSampleSeconds: Double = SystemStats.cpuTimeSeconds()
    private var lastGPUFrameMs: Double = 0

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

    // Day/night cycle: purely a function of elapsedTime, same as wave/
    // foliage animation — it keeps advancing while paused/in menus, not
    // just during active play. 12 in-game hours pass every 10 real
    // minutes, so a full 24-hour cycle takes 20 real minutes.
    private static let secondsPerGameHour: Float = (10 * 60) / 12
    private let nightFogColor = SIMD3<Float>(0.04, 0.05, 0.10)
    private let sunDistance: Float = 300
    private let sunSize: Float = 30
    private let moonSize: Float = 24
    private let moonColor = SIMD3<Float>(0.80, 0.83, 0.92)

    /// 0..<24, wrapping — the H overlay's clock (see logBenchmark).
    var gameHours: Float {
        let hours = elapsedTime / Self.secondsPerGameHour
        return hours.truncatingRemainder(dividingBy: 24)
    }

    /// World-space direction toward the sun right now: rises at hour 6,
    /// peaks straight overhead at noon, sets at hour 18, dips below the
    /// horizon (negative y) overnight. Drives both the directional light
    /// and where the sun disc itself is drawn (see draw(in:)/drawSun).
    private var sunDirection: SIMD3<Float> {
        let angle = (gameHours - 6) / 12 * Float.pi
        return normalize(SIMD3<Float>(cos(angle), sin(angle), 0.35))
    }

    /// 0 at night, 1 at midday, with a gradient through sunrise/sunset
    /// rather than a hard cutoff right at the horizon — blends the sky/fog
    /// color and the sun disc's own tint (see drawSun).
    private var daylightFactor: Float {
        Math.clamp(sunDirection.y + 0.5, 0, 1)
    }

    init(device: MTLDevice, inputController: InputController, world: WorldMeta) {
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

        guard let postVertexFunction = library.makeFunction(name: "vertex_post"),
              let postFragmentFunction = library.makeFunction(name: "fragment_post") else {
            fatalError("Could not find post-process shader functions")
        }
        let postPipelineDescriptor = MTLRenderPipelineDescriptor()
        postPipelineDescriptor.vertexFunction = postVertexFunction
        postPipelineDescriptor.fragmentFunction = postFragmentFunction
        postPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.postProcessPipelineState = try device.makeRenderPipelineState(descriptor: postPipelineDescriptor)
        } catch {
            fatalError("Could not create post-process pipeline state: \(error)")
        }

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
        // A world is just its seed (TerrainGenerator is a pure function of
        // it) plus every edit — WorldStore already wrote/loaded those before
        // this Renderer was ever constructed (see AppDelegate.startGame), so
        // this just replays the edits on top before anything else touches
        // blockEdits/generator.
        let generator = TerrainGenerator(seed: world.seed, worldHeight: worldHeight)
        let villageGenerator = VillageGenerator(seed: world.seed, terrainGenerator: generator)
        let blockEdits = self.blockEdits
        blockEdits.load(WorldStore.loadEdits(for: world.id))
        self.chunkManager = ChunkManager(device: device, generator: generator, villageGenerator: villageGenerator, blockEdits: blockEdits, chunkSize: chunkSize, worldHeight: worldHeight)

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
            if let village = villageGenerator.block(x: x, y: y, z: z) {
                return village
            }
            return generator.proceduralBlock(x: x, y: y, z: z, worldHeight: worldHeight)
        }

        // VoxelType.isSolid means "opaque for rendering" (it's only false for
        // .air) — water is deliberately "solid" by that definition, since the
        // mesher needs it to block/cull faces. But every query below means
        // "solid" as in "blocks the player" — water should never count there,
        // since swimming into it is exactly what's supposed to happen.
        func isObstacle(_ type: VoxelType) -> Bool {
            type.isSolid && type != .water
        }

        // The real solid terrain surface — no sea-level clamping, since
        // PlayerController's swimming physics needs to know how deep a
        // lakebed actually is, not just that it's underwater. +1 because a
        // solid voxel at index `height` spans world y in [height, height+1]
        // (see VoxelMesher/cubeCorners) — the walkable surface is its top
        // face, not the voxel's own coordinate.
        //
        // Fast path when nobody's edited this column AND the natural surface
        // itself isn't a cave/ravine mouth (see TerrainGenerator.isCarved —
        // a ravine can carve right through the nominal surface block): the
        // O(1) procedural answer, same as before caves/edits existed at all.
        // Anything else pays for scanning down from the higher of the
        // procedural height or the highest edit to find the true topmost
        // solid block, all the way to bedrock — a ravine can run up to
        // ravineMaxDepth blocks deep, so unlike edits (bounded by how far
        // the player's actually built) this can't assume a shallow floor.
        let groundHeight: (Float, Float) -> Float = { x, z in
            let ix = Int(x.rounded(.down))
            let iz = Int(z.rounded(.down))
            // A village flattens/replaces terrain across its whole footprint
            // (see VillageGenerator), so its surface height can't be derived
            // from TerrainGenerator's own (unmodified) column height — use it
            // as this column's base height instead, the same role
            // proceduralHeight plays outside a village. This must NOT skip
            // the edit-aware slow path below when there IS a player edit
            // here — a village column can be dug into or built on exactly
            // like any other, and the fast path returning a fixed height
            // regardless would silently ignore that (the mesh still shows
            // the edit correctly, since Chunk/blockAt check edits first, but
            // physics would float/clip through it).
            let villageHeight = villageGenerator.flattenedHeight(x: ix, z: iz)
            let baseHeight = villageHeight ?? generator.columnInfo(x: ix, z: iz).height
            let editRange = blockEdits.editedYRange(x: ix, z: iz)
            // Villages are never carved (their own eligibility check already
            // rejects cave/ravine sites), so isCarved only needs checking in
            // the natural-terrain case.
            if editRange == nil, villageHeight != nil || !generator.isCarved(x: ix, y: baseHeight, z: iz, surfaceHeight: baseHeight) {
                return Float(baseHeight + 1)
            }
            var y = max(baseHeight, editRange?.upperBound ?? baseHeight) + 1
            while y >= 0 {
                if isObstacle(blockAt(ix, y, iz)) { return Float(y + 1) }
                y -= 1
            }
            return 1 // bedrock fallback; proceduralBlock always returns solid stone below y=0 anyway
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
                if isObstacle(blockAt(ix, y, iz)) { return true }
            }
            return false
        }

        // General point-in-solid query, used by the third-person camera to
        // stop short of clipping through terrain/trees/placed blocks behind
        // the player (water doesn't count — the camera should follow right
        // in when the player swims, not treat the surface as a wall), and by
        // the break/place raycast to find a target (so it passes through
        // water to whatever's beyond/beneath it, instead of "breaking" water).
        let isSolidAt: (Float, Float, Float) -> Bool = { x, y, z in
            isObstacle(blockAt(Int(x.rounded(.down)), Int(y.rounded(.down)), Int(z.rounded(.down))))
        }

        // Spawn column: search outward in rings from the origin for one
        // whose natural surface isn't a cave/ravine mouth (see
        // TerrainGenerator.isCarved) — a carved column's "ground" is
        // actually that cave/ravine's own floor, which can be deep and
        // enclosed (groundHeight would happily walk down into it, same as
        // it does for any other overhang) rather than a safe, open place to
        // start the game. Falls back to the origin itself in the
        // astronomically unlikely case every ring up to radius 32 is carved.
        func findSpawnColumn() -> (x: Int, z: Int) {
            for radius in 0...32 {
                for dz in -radius...radius {
                    for dx in -radius...radius {
                        guard max(abs(dx), abs(dz)) == radius else { continue } // only this ring's perimeter
                        let x = 8 + dx
                        let z = 8 + dz
                        let info = generator.columnInfo(x: x, z: z)
                        if !generator.isCarved(x: x, y: info.height, z: z, surfaceHeight: info.height) {
                            return (x, z)
                        }
                    }
                }
            }
            return (8, 8)
        }
        let spawnColumn = findSpawnColumn()
        let spawnHeight = groundHeight(Float(spawnColumn.x), Float(spawnColumn.z))
        let camera = Camera(position: SIMD3<Float>(Float(spawnColumn.x), spawnHeight, Float(spawnColumn.z)), yaw: 0, pitch: 0)
        self.camera = camera
        let playerController = PlayerController(
            camera: camera,
            groundHeight: groundHeight,
            waterSurfaceHeight: waterSurfaceHeight,
            isObstructed: isObstructed,
            isSolidAt: isSolidAt
        )
        camera.position.y = spawnHeight + playerController.eyeHeight
        self.spawnPosition = camera.position
        self.playerController = playerController
        let playerVitals = PlayerVitals(health: world.health, hunger: world.hunger)
        self.playerVitals = playerVitals
        self.lastPersistedHealth = playerVitals.health
        self.lastPersistedHunger = playerVitals.hunger
        self.isSolidAt = isSolidAt
        self.waterSurfaceHeight = waterSurfaceHeight
        self.blockAt = blockAt
        self.groundHeight = groundHeight
        self.terrainGenerator = generator
        self.villageGenerator = villageGenerator
        self.worldID = world.id
        self.hotbar = Hotbar(gameMode: .creative)
        self.animalManager = AnimalManager(terrainGenerator: generator, villageGenerator: villageGenerator, groundHeight: groundHeight, waterSurfaceHeight: waterSurfaceHeight)
        self.villagerManager = VillagerManager(villageGenerator: villageGenerator, groundHeight: groundHeight, waterSurfaceHeight: waterSurfaceHeight)

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspectRatio = size.width > 0 && size.height > 0 ? Float(size.width / size.height) : 1
        currentDrawableSize = size
        rebuildOffscreenTextures()
    }

    /// Must be called (with the MTKView's draw loop already stopped, so
    /// nothing new is calling draw() concurrently) before this Renderer is
    /// released — see AppDelegate.quitToTitle. draw()'s wait() is matched by
    /// a signal() from the GPU's completion handler, which can still be
    /// pending for up to maxBuffersInFlight frames after the last draw()
    /// call returns; deallocating inFlightSemaphore while any of those are
    /// still outstanding traps in libdispatch (a semaphore can only be
    /// disposed at its starting count). Re-acquiring every permit here
    /// blocks until all of them have actually signaled, then immediately
    /// hands them back so the semaphore is at its initial count either way.
    func waitForPendingFrames() {
        for _ in 0..<maxBuffersInFlight {
            inFlightSemaphore.wait()
        }
        for _ in 0..<maxBuffersInFlight {
            inFlightSemaphore.signal()
        }
    }

    /// Settings-menu hook: renders the scene into an offscreen texture at
    /// `scale` × the drawable's size, which the post-process pass then
    /// stretches to fill the actual drawable — lower scales trade visual
    /// crispness for fewer shaded pixels per frame.
    func setResolutionScale(_ scale: Float) {
        resolutionScale = scale
        rebuildOffscreenTextures()
    }

    /// Settings-menu hook.
    func setPostEffect(_ effect: PostEffect) {
        postEffect = effect
    }

    private func rebuildOffscreenTextures() {
        guard currentDrawableSize.width > 0, currentDrawableSize.height > 0 else { return }
        let width = max(1, Int(Float(currentDrawableSize.width) * resolutionScale))
        let height = max(1, Int(Float(currentDrawableSize.height) * resolutionScale))

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        sceneColorTexture = device.makeTexture(descriptor: colorDescriptor)

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        sceneDepthTexture = device.makeTexture(descriptor: depthDescriptor)
    }

    func draw(in view: MTKView) {
        inFlightSemaphore.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.inFlightSemaphore.signal()
            // gpuStartTime/EndTime are only valid once the buffer's actually
            // completed (here) — fires on a Metal-internal thread, so hop to
            // main before touching lastGPUFrameMs, same as ChunkManager's
            // background-build handoff.
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            DispatchQueue.main.async {
                self?.lastGPUFrameMs = gpuMs
            }
        }

        let now = CACurrentMediaTime()
        let deltaTime = Float(now - lastFrameTime)
        lastFrameTime = now
        elapsedTime += deltaTime
        onFrameTick?(deltaTime)
        // Chunk streaming keeps running even while paused, so the world
        // around spawn is already loaded by the time the player hits Play —
        // only the player's own movement/physics freezes.
        if !isPaused {
            playerController.update(input: inputController, deltaTime: deltaTime)
            hotbar.update(input: inputController)
            updateSurvivalBreaking(deltaTime: deltaTime)
            updateDroppedItems(deltaTime: deltaTime)
            animalManager.update(around: camera.position, deltaTime: deltaTime)
            for deadAnimal in animalManager.removeDeadAnimals() {
                spawnAnimalDrops(for: deadAnimal)
            }
            villagerManager.update(around: camera.position, deltaTime: deltaTime)
            updatePlayerVitals(deltaTime: deltaTime)
        }
        updateCraftingTableProximity()
        onHotbarChanged?(hotbar.slots, hotbar.selectedIndex)
        onBreakProgressChanged?(breakingProgress)
        onVitalsChanged?(playerVitals.health, PlayerVitals.maxHealth, playerVitals.hunger, PlayerVitals.maxHunger)
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
        let skyColor = Math.mix(nightFogColor, fogColor, daylightFactor)
        let currentFogColor = isCameraUnderwater ? underwaterFogColor : skyColor
        let currentFogDistance = isCameraUnderwater ? underwaterFogDistance : fogDistance
        let sunDirection = self.sunDirection

        let modelMatrix = matrix_identity_float4x4
        let projectionMatrix = Math.perspective(fovyRadians: .pi / 4, aspect: aspectRatio, near: 0.1, far: farPlane)
        let viewProjectionMatrix = projectionMatrix * camera.viewMatrix

        var uniforms = Uniforms(
            modelMatrix: modelMatrix,
            viewProjectionMatrix: viewProjectionMatrix,
            normalMatrix: matrix_identity_float3x3,
            lightDirection: -sunDirection,
            cameraPosition: eyePosition,
            fogColor: currentFogColor,
            fogDistance: currentFogDistance,
            time: elapsedTime
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        guard let drawable = view.currentDrawable,
              let sceneColorTexture, let sceneDepthTexture else {
            inFlightSemaphore.signal()
            return
        }

        // Scene renders into an offscreen texture (its own resolution,
        // independent of the drawable — see setResolutionScale) rather than
        // straight to the drawable; the post-process pass below samples it
        // and stretches it to fill the actual screen.
        let scenePassDescriptor = MTLRenderPassDescriptor()
        scenePassDescriptor.colorAttachments[0].texture = sceneColorTexture
        scenePassDescriptor.colorAttachments[0].loadAction = .clear
        scenePassDescriptor.colorAttachments[0].storeAction = .store
        scenePassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(currentFogColor.x), green: Double(currentFogColor.y), blue: Double(currentFogColor.z), alpha: 1.0
        )
        scenePassDescriptor.depthAttachment.texture = sceneDepthTexture
        scenePassDescriptor.depthAttachment.loadAction = .clear
        scenePassDescriptor.depthAttachment.storeAction = .dontCare
        scenePassDescriptor.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePassDescriptor) else {
            inFlightSemaphore.signal()
            return
        }

        // Every voxel face is wound so front == outward normal, so hardware culling
        // is safe here and drops the ~half of exposed faces facing away each frame.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)

        // Drawn first, color-only (waterDepthState doesn't write depth): the
        // opaque terrain below overwrites it pixel-for-pixel wherever
        // something solid is actually in front, so this needs no depth
        // comparison of its own to be correctly hidden behind hills/trees —
        // the standard "skybox drawn first" ordering. The moon sits exactly
        // opposite the sun (same great circle), so it's up whenever the sun
        // is down and vice versa — no separate day/night gating needed,
        // "below the horizon" already means "behind the terrain that just
        // got drawn over it" via that same mechanism.
        let sunColor = Math.mix(SIMD3<Float>(1.0, 0.55, 0.25), SIMD3<Float>(1.0, 0.98, 0.85), daylightFactor)
        drawCelestialBody(direction: sunDirection, distance: sunDistance, size: sunSize, color: sunColor, with: encoder)
        drawCelestialBody(direction: -sunDirection, distance: sunDistance, size: moonSize, color: moonColor, with: encoder)
        encoder.setCullMode(.back) // the calls above leave it at .none for their own billboards — restore before opaque terrain

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

        // Still the opaque pipeline/depth state — dropped items are solid,
        // lit cubes like anything else, just rebuilt fresh each frame.
        drawDroppedItems(with: encoder)
        drawAnimals(with: encoder)
        drawVillagers(with: encoder)

        // Foliage: same opaque depth state as terrain (it writes depth, no
        // blending), just a different vertex function for the wind sway.
        encoder.setRenderPipelineState(foliagePipelineState)
        for chunk in chunkManager.loadedChunks.values {
            draw(chunk.foliage, with: encoder)
        }

        if let hit = raycastTargetBlock() {
            let progress = (hit.block == breakingTarget) ? breakingProgress : 0
            drawBlockHighlight(around: hit.block, progress: progress, with: encoder)
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
        // Side faces render even against a solid neighbor, not just air
        // (see Chunk's water meshing doc comment — deliberate, so a
        // submerged lakebed wall still reads as a "wall of depth"), which
        // means that face and the solid block's own face behind it sit at
        // the exact same plane. Two coincident surfaces z-fight: floating-
        // point differences between this pipeline's and the opaque
        // pipeline's matrix math make it a coin flip per pixel which one
        // wins. A small negative depth bias reliably tips that coin toward
        // water instead of nudging any actual vertex position — nudging
        // geometry instead (tried first) opened a seam where the moved side
        // face no longer lined up with its own unmoved top face.
        encoder.setDepthBias(-2, slopeScale: -1, clamp: -0.0005)
        for chunk in chunkManager.loadedChunks.values {
            draw(chunk.water, with: encoder)
        }
        encoder.endEncoding()

        // Post-process pass: a full-screen triangle sampling sceneColorTexture
        // straight into the drawable. Always runs, even for .none, so there's
        // one code path regardless of which effect (or resolution scale) is
        // active — the shader itself just passes color through unmodified.
        guard let postPassDescriptor = view.currentRenderPassDescriptor else {
            inFlightSemaphore.signal()
            return
        }
        postPassDescriptor.colorAttachments[0].loadAction = .dontCare
        postPassDescriptor.depthAttachment.texture = nil

        guard let postEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: postPassDescriptor) else {
            inFlightSemaphore.signal()
            return
        }
        postEncoder.setRenderPipelineState(postProcessPipelineState)
        postEncoder.setFragmentTexture(sceneColorTexture, index: 0)
        var postUniforms = PostEffectUniforms(effect: Int32(postEffect.rawValue))
        postEncoder.setFragmentBytes(&postUniforms, length: MemoryLayout<PostEffectUniforms>.stride, index: 0)
        postEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        postEncoder.endEncoding()

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

        let currentCPUSeconds = SystemStats.cpuTimeSeconds()
        // Raw user+sys time summed across cores can exceed 100% on a
        // multi-core machine (Activity Monitor's convention) — dividing by
        // core count instead normalizes to 0...100 as "share of the whole
        // machine," which reads more like a usual "usage" percentage.
        let rawCPUPercent = (currentCPUSeconds - lastCPUSampleSeconds) / Double(benchWindowSeconds) * 100
        let cpuPercent = min(rawCPUPercent / Double(ProcessInfo.processInfo.activeProcessorCount), 100)
        lastCPUSampleSeconds = currentCPUSeconds
        let memoryMB = Double(SystemStats.memoryFootprintBytes()) / 1_048_576
        // % of the frame's own time budget the GPU was actually busy — not
        // system-wide GPU utilization (no public API for that), just how
        // much of each frame this renderer's own draw calls occupied it.
        let gpuPercentOfFrame = avgMs > 0 ? lastGPUFrameMs / avgMs * 100 : 0

        print(String(
            format: "[bench] fps=%.1f avgFrameMs=%.2f maxFrameMs=%.2f loadedChunks=%d pending=%d triangles=%d chunkBuilds=%d avgChunkBuildMs=%.2f pos=(%.2f,%.2f,%.2f) grounded=%d swimming=%d cpu=%.1f%% mem=%.0fMB gpu=%.2fms",
            fps, avgMs, benchFrameMsMax,
            chunkManager.loadedChunks.count, chunkManager.pendingChunkCount, chunkManager.totalTriangleCount,
            chunkManager.totalChunksBuilt, chunkManager.averageChunkBuildMs,
            camera.position.x, camera.position.y, camera.position.z,
            playerController.isGrounded ? 1 : 0,
            playerController.isSwimming ? 1 : 0,
            cpuPercent, memoryMB, lastGPUFrameMs
        ))

        let posText = String(format: "%.1f, %.1f, %.1f", camera.position.x, camera.position.y, camera.position.z)
        let totalMinutes = Int(gameHours * 60)
        let timeText = String(format: "%02d:%02d", (totalMinutes / 60) % 24, totalMinutes % 60)
        let statsText = """
        FPS: \(Int(fps.rounded())) (\(String(format: "%.1f", avgMs)) ms)
        Pos: \(posText)
        Time: \(timeText)
        Grounded: \(playerController.isGrounded ? "yes" : "no")   Swimming: \(playerController.isSwimming ? "yes" : "no")
        Third-person: \(camera.isThirdPerson ? "yes" : "no")
        Chunks: \(chunkManager.loadedChunks.count) loaded, \(chunkManager.pendingChunkCount) pending
        Triangles: \(chunkManager.totalTriangleCount)
        CPU: \(String(format: "%.0f", cpuPercent))%   Mem: \(String(format: "%.0f", memoryMB)) MB
        GPU: \(String(format: "%.2f", lastGPUFrameMs)) ms (\(String(format: "%.0f", gpuPercentOfFrame))% of frame)
        """
        onStatsUpdate?(statsText)

        benchWindowSeconds = 0
        benchFrameCount = 0
        benchFrameMsSum = 0
        benchFrameMsMax = 0
    }

    /// MapView hook: the natural terrain color at this column — water blue
    /// at/under sea level, otherwise whatever TerrainGenerator would surface
    /// there. Deliberately ignores player edits (blockEdits): a map reads
    /// the land, not which blocks you've personally dug or placed.
    func terrainColor(x: Int, z: Int) -> SIMD3<Float> {
        let info = terrainGenerator.columnInfo(x: x, z: z)
        return info.height <= TerrainGenerator.seaLevel ? VoxelType.water.color : info.topBlock.color
    }

    /// Fire-and-forget: called after every break/place. The snapshot copy
    /// (BlockEdits.allEdits, under its own lock) and the encode+write both
    /// happen on saveQueue, off the main thread, so an edit never stalls a
    /// frame waiting on disk I/O.
    private func persistSave() {
        saveQueue.async { [worldID, blockEdits] in
            WorldStore.saveEdits(blockEdits.allEdits(), for: worldID)
        }
    }

    /// Fire-and-forget, mirrors persistSave — called only when health/hunger
    /// actually changed (see updatePlayerVitals), not every frame, since
    /// that would mean a disk write per frame while starving/regenerating.
    private func persistVitals() {
        let health = playerVitals.health
        let hunger = playerVitals.hunger
        saveQueue.async { [worldID] in
            WorldStore.saveVitals(health: health, hunger: hunger, for: worldID)
        }
    }

    /// Blocking variant for app shutdown/quit-to-title (see AppDelegate) —
    /// there's no next frame to let an async persistSave finish on, so this
    /// waits on saveQueue instead of just enqueueing onto it.
    func saveNow() {
        let health = playerVitals.health
        let hunger = playerVitals.hunger
        saveQueue.sync { [worldID, blockEdits] in
            WorldStore.saveEdits(blockEdits.allEdits(), for: worldID)
            WorldStore.saveVitals(health: health, hunger: hunger, for: worldID)
        }
    }

    /// Survival-only (creative players are invincible/never hungry, matching
    /// how creative already skips break-progress and gives infinite items).
    /// fallDamage is derived here from PlayerController's landing state
    /// rather than inside PlayerVitals, since only Renderer knows the
    /// block-scale safe-fall threshold that turns a fall distance into damage.
    private func updatePlayerVitals(deltaTime: Float) {
        guard gameMode == .survival else { return }

        var fallDamage = 0
        if playerController.justLanded, playerController.lastFallDistance > PlayerVitals.safeFallDistance {
            let excessBlocks = Int((playerController.lastFallDistance - PlayerVitals.safeFallDistance).rounded(.up))
            fallDamage = excessBlocks * PlayerVitals.fallDamagePerBlock
        }
        playerVitals.update(deltaTime: deltaTime, fallDamage: fallDamage)

        if playerVitals.health != lastPersistedHealth || playerVitals.hunger != lastPersistedHunger {
            lastPersistedHealth = playerVitals.health
            lastPersistedHunger = playerVitals.hunger
            persistVitals()
        }

        if playerVitals.isDead {
            camera.position = spawnPosition
            playerVitals.respawn()
            onToastMessage?("You died")
        }
    }

    /// Recomputed every frame (see draw(in:)) rather than only while the
    /// inventory is open — cheap (a few dozen blockAt calls), and simpler
    /// than threading an "inventory just opened" event down to Renderer.
    private func updateCraftingTableProximity() {
        let feetX = Int(camera.position.x.rounded())
        let feetY = Int((camera.position.y - playerController.eyeHeight).rounded())
        let feetZ = Int(camera.position.z.rounded())
        let radius = Self.craftingTableSearchRadius
        for dy in -2...2 {
            for dz in -radius...radius {
                for dx in -radius...radius {
                    if blockAt(feetX + dx, feetY + dy, feetZ + dz) == .craftingTable {
                        isNearCraftingTable = true
                        return
                    }
                }
            }
        }
        isNearCraftingTable = false
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

    private let animalHitReach: Float = 4.5
    private let animalHitRadius: Float = 0.6

    /// Nearest animal roughly along the camera's look direction within
    /// reach — used to prioritize attacking over breaking whatever block is
    /// behind it. Unlike raycastTargetBlock's voxel marching, this is just a
    /// closest-point-to-ray check against each animal's body center, since
    /// an animal isn't grid-aligned the way a block is.
    private func targetedAnimal() -> Animal? {
        let origin = camera.position
        let direction = camera.front
        var best: Animal?
        var bestDistance = animalHitReach
        for animal in animalManager.animals {
            let bodyCenter = animal.position + SIMD3<Float>(0, 0.3, 0)
            let toAnimal = bodyCenter - origin
            let alongRay = dot(toAnimal, direction)
            guard alongRay > 0, alongRay < bestDistance else { continue }
            let closestPoint = origin + direction * alongRay
            guard length(bodyCenter - closestPoint) < animalHitRadius else { continue }
            bestDistance = alongRay
            best = animal
        }
        return best
    }

    /// Left click, tried before breakTargetedBlock/updateSurvivalBreaking —
    /// attacking works in both game modes (unlike block breaking's
    /// creative-only instant break), matching the usual "same button hits
    /// whatever you're looking at" convention. Returns whether an animal was
    /// actually hit, so the caller knows not to also try breaking a block
    /// this click.
    @discardableResult
    func attackTargetedAnimal() -> Bool {
        guard !isPaused, let animal = targetedAnimal() else { return false }
        let away = SIMD2<Float>(animal.position.x - camera.position.x, animal.position.z - camera.position.z)
        let awayLength = length(away)
        animal.hit(awayFromPlayer: awayLength > 0.0001 ? away / awayLength : SIMD2<Float>(0, 1))
        return true
    }

    /// Nearest villager roughly along the camera's look direction within
    /// reach — same closest-point-to-ray shape as targetedAnimal, just
    /// against villagerManager.villagers.
    private func targetedVillager() -> Villager? {
        let origin = camera.position
        let direction = camera.front
        var best: Villager?
        var bestDistance = animalHitReach
        for villager in villagerManager.villagers {
            let bodyCenter = villager.position + SIMD3<Float>(0, 0.6, 0)
            let toVillager = bodyCenter - origin
            let alongRay = dot(toVillager, direction)
            guard alongRay > 0, alongRay < bestDistance else { continue }
            let closestPoint = origin + direction * alongRay
            guard length(bodyCenter - closestPoint) < animalHitRadius else { continue }
            bestDistance = alongRay
            best = villager
        }
        return best
    }

    /// Right click, tried before placeBlock — mirrors attackTargetedAnimal's
    /// priority pattern for left click. Executes the targeted villager's
    /// fixed trade immediately if the player has enough of what it wants,
    /// otherwise just reports what's missing. Returns whether a villager was
    /// targeted at all (trade attempted, successful or not), so the caller
    /// knows not to also place a block this click.
    @discardableResult
    func tradeWithTargetedVillager() -> Bool {
        guard !isPaused, let villager = targetedVillager() else { return false }
        let recipe = villager.tradeRecipe
        guard hotbar.count(of: recipe.give.type) >= recipe.give.count else {
            onToastMessage?("Need \(recipe.give.count) \(recipe.give.type.displayName)")
            return true
        }
        // A slot already holding this type always has room (no per-slot
        // stack cap — see Hotbar.addItem); otherwise there needs to be an
        // empty slot free. Checked before removing anything the player pays,
        // so a full hotbar can't eat the payment for nothing in return.
        let hasRoom = hotbar.slots.contains { $0.type == recipe.receive.type } || hotbar.slots.contains { $0.type == nil }
        guard hasRoom else {
            onToastMessage?("No room for \(recipe.receive.type.displayName)")
            return true
        }
        hotbar.remove(recipe.give.type, count: recipe.give.count)
        hotbar.addItems(recipe.receive.type, count: recipe.receive.count)
        onToastMessage?("Traded for \(recipe.receive.count) \(recipe.receive.type.displayName)")
        return true
    }

    /// Right click, tried before placeBlock (after tradeWithTargetedVillager)
    /// — same priority-chain pattern. Only the selected slot's held item can
    /// be eaten, no separate "eat" input. Creative doesn't need food at all,
    /// so this only ever does something in survival. Returns whether eating
    /// was attempted at all, so the caller knows not to also place a block.
    @discardableResult
    func eatSelectedFood() -> Bool {
        guard !isPaused, gameMode == .survival, let selectedType = hotbar.selectedType,
              playerVitals.eat(selectedType) else { return false }
        hotbar.consumeSelected()
        return true
    }

    /// Left click: in creative, removes whatever block the player is looking
    /// at instantly — no drop, matching "you already have infinite blocks."
    /// In survival, breaking instead happens gradually in updateSurvivalBreaking
    /// (driven by the held mouse button, not this discrete click), so this
    /// is a no-op there.
    func breakTargetedBlock() {
        guard !isPaused, gameMode == .creative, let hit = raycastTargetBlock() else { return }
        blockEdits.set(BlockCoord(hit.block), to: .air)
        chunkManager.rebuildAffectedChunks(byEditAt: hit.block)
        persistSave()
    }

    /// Right click: places the hotbar's selected block into the empty cell
    /// adjacent to whatever face the player is looking at. In survival,
    /// consumes one from that slot — an empty slot (nothing selected) simply
    /// can't place anything.
    func placeBlock() {
        guard !isPaused, let hit = raycastTargetBlock(), let placeAt = hit.placeAt,
              let selectedType = hotbar.selectedType,
              selectedType.isSolid // tools/food/materials (map, meat, bones, ...) aren't real blocks
        else { return }

        // Don't let the player wall themselves in.
        let playerColumnX = Int(camera.position.x.rounded(.down))
        let playerColumnZ = Int(camera.position.z.rounded(.down))
        let feetY = Int((camera.position.y - playerController.eyeHeight).rounded(.down))
        let headY = Int(camera.position.y.rounded(.down))
        if placeAt.x == playerColumnX, placeAt.z == playerColumnZ, placeAt.y >= feetY, placeAt.y <= headY {
            return
        }

        blockEdits.set(BlockCoord(placeAt), to: selectedType)
        chunkManager.rebuildAffectedChunks(byEditAt: placeAt)
        persistSave()
        if gameMode == .survival {
            hotbar.consumeSelected()
        }
    }

    /// Settings-menu hook. Resets the hotbar for the new mode (survival
    /// clears it — you don't keep creative's free blocks; switching back to
    /// creative refills it) and cancels any in-progress break.
    func setGameMode(_ mode: GameMode) {
        gameMode = mode
        hotbar.reset(for: mode)
        breakingTarget = nil
        breakingProgress = 0
    }

    /// Advances survival's held-to-break progress against whatever's
    /// currently targeted. Switching targets (or letting go, or the mode not
    /// being survival) resets progress rather than pausing it — no
    /// accumulating partial progress on a block by tapping at it repeatedly.
    private func updateSurvivalBreaking(deltaTime: Float) {
        guard gameMode == .survival, inputController.isLeftMouseDown,
              let hit = raycastTargetBlock() else {
            breakingTarget = nil
            breakingProgress = 0
            return
        }

        if breakingTarget != hit.block {
            breakingTarget = hit.block
            breakingProgress = 0
        }

        let type = blockAt(hit.block.x, hit.block.y, hit.block.z)
        breakingProgress += deltaTime / type.breakDuration
        guard breakingProgress >= 1 else { return }

        blockEdits.set(BlockCoord(hit.block), to: .air)
        chunkManager.rebuildAffectedChunks(byEditAt: hit.block)
        persistSave()
        droppedItems.append(DroppedItem(
            type: type,
            position: SIMD3<Float>(Float(hit.block.x) + 0.5, Float(hit.block.y) + 0.5, Float(hit.block.z) + 0.5),
            spawnTime: CACurrentMediaTime()
        ))
        breakingTarget = nil
        breakingProgress = 0
    }

    /// Called once per killed animal (see draw(in:)'s removeDeadAnimals
    /// loop) — a bit of meat plus a chance at a bone, dropped as ordinary
    /// DroppedItems so they fall/get picked up exactly like anything broken
    /// out of terrain.
    private func spawnAnimalDrops(for animal: Animal) {
        let meatType: VoxelType
        switch animal.type {
        case .pig: meatType = .rawPork
        case .sheep: meatType = .rawMutton
        case .chicken: meatType = .rawChicken
        }

        var drops = Array(repeating: meatType, count: Int.random(in: 1...2))
        if Float.random(in: 0...1) < 0.35 {
            drops.append(.bone)
        }

        for drop in drops {
            let scatter = SIMD3<Float>(Float.random(in: -0.2...0.2), 0.3, Float.random(in: -0.2...0.2))
            droppedItems.append(DroppedItem(type: drop, position: animal.position + scatter, spawnTime: CACurrentMediaTime()))
        }
    }

    /// The nearest solid surface at or below `y` in this column, scanning
    /// downward from the item's own current height — unlike groundHeight
    /// (which finds the column's overall topmost surface, correct for
    /// player-standing but wrong here), this finds the actual floor
    /// underneath an item that's falling inside a cave, tunnel, or overhang,
    /// rather than the outer hill surface somewhere above it.
    private func floorHeight(x: Float, z: Float, below y: Float) -> Float {
        let ix = Int(x.rounded(.down))
        let iz = Int(z.rounded(.down))
        var scanY = Int(y.rounded(.down))
        let hardFloor = -4 // proceduralBlock treats y < 0 as solid stone, so this is never actually reached
        while scanY > hardFloor {
            if isSolidAt(Float(ix) + 0.5, Float(scanY), Float(iz) + 0.5) {
                return Float(scanY + 1)
            }
            scanY -= 1
        }
        return Float(hardFloor + 1)
    }

    /// Falls each item toward the nearest floor beneath it, picks up any
    /// within reach, and clears out old ones nobody collected.
    private func updateDroppedItems(deltaTime: Float) {
        guard !droppedItems.isEmpty else { return }
        let now = CACurrentMediaTime()
        let pickupRadiusSq = itemPickupRadius * itemPickupRadius
        // Measured from the feet, not the eye/camera position — an item
        // resting on the ground is roughly at foot height, and comparing
        // against eye height (playerController.eyeHeight above that) would
        // put it outside the pickup radius even standing right on top of it.
        let feetPosition = SIMD3<Float>(camera.position.x, camera.position.y - playerController.eyeHeight, camera.position.z)
        var remaining: [DroppedItem] = []
        remaining.reserveCapacity(droppedItems.count)
        for var item in droppedItems {
            // Rests with its center droppedItemSize/2 above the surface, so
            // its bottom face sits flush on the ground rather than half-buried.
            let restHeight = floorHeight(x: item.position.x, z: item.position.z, below: item.position.y) + droppedItemSize / 2
            if item.position.y > restHeight {
                item.verticalVelocity -= droppedItemGravity * deltaTime
                item.position.y = max(restHeight, item.position.y + item.verticalVelocity * deltaTime)
                if item.position.y <= restHeight {
                    item.verticalVelocity = 0
                }
            } else {
                item.verticalVelocity = 0
            }

            let dx = item.position.x - feetPosition.x
            let dy = item.position.y - feetPosition.y
            let dz = item.position.z - feetPosition.z
            // Only actually consumed if the hotbar had room — addItem
            // returns false when every slot is full of some other type, and
            // an item that couldn't be picked up should stay on the ground
            // (and remain eligible for despawn below) rather than vanishing.
            if dx * dx + dy * dy + dz * dz < pickupRadiusSq, hotbar.addItem(item.type) {
                continue
            }
            if now - item.spawnTime > itemDespawnSeconds {
                continue
            }
            remaining.append(item)
        }
        droppedItems = remaining
    }

    private func drawDroppedItems(with encoder: MTLRenderCommandEncoder) {
        guard !droppedItems.isEmpty else { return }
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        for item in droppedItems {
            let age = Float(CACurrentMediaTime() - item.spawnTime)
            // abs() keeps the bob from ever dipping the item below the ground
            // it just landed on — a resting item gently hops rather than
            // sinking half a cycle into the floor.
            let bob = abs(sin(age * 2.5)) * 0.08
            let center = item.position + SIMD3<Float>(0, bob, 0)
            DroppedItemMesh.appendCube(center: center, size: droppedItemSize, yaw: age * 1.4, color: item.type.color, into: &vertices, indices: &indices)
        }
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared) else {
            return
        }
        draw(ChunkGeometry(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count), with: encoder)
    }

    // Rebuilt fresh every frame from AnimalManager's current list — same
    // reasoning as dropped items/PlayerModel: cheap enough per-frame that a
    // persistent buffer per animal isn't worth the bookkeeping, especially
    // since the population itself changes as animals spawn/despawn.
    private func drawAnimals(with encoder: MTLRenderCommandEncoder) {
        let animals = animalManager.animals
        guard !animals.isEmpty else { return }
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        for animal in animals {
            let (animalVertices, animalIndices) = AnimalMesh.buildMesh(
                type: animal.type, feetPosition: animal.position, yaw: animal.yaw, walkBobPhase: animal.walkBobPhase,
                hitFlash: animal.hitFlashIntensity
            )
            let start = UInt32(vertices.count)
            vertices.append(contentsOf: animalVertices)
            indices.append(contentsOf: animalIndices.map { $0 + start })
        }
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared) else {
            return
        }
        draw(ChunkGeometry(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count), with: encoder)
    }

    private func drawVillagers(with encoder: MTLRenderCommandEncoder) {
        let villagers = villagerManager.villagers
        guard !villagers.isEmpty else { return }
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        for villager in villagers {
            let (villagerVertices, villagerIndices) = VillagerMesh.buildMesh(
                feetPosition: villager.position, yaw: villager.yaw, walkBobPhase: villager.walkBobPhase
            )
            let start = UInt32(vertices.count)
            vertices.append(contentsOf: villagerVertices)
            indices.append(contentsOf: villagerIndices.map { $0 + start })
        }
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared) else {
            return
        }
        draw(ChunkGeometry(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count), with: encoder)
    }

    // Rebuilt fresh every frame around whatever block is targeted (see
    // BlockHighlight) — trivially cheap (24 vertices), so no need to cache.
    // `progress` (0...1, only nonzero mid-survival-break) shifts the outline
    // from its resting near-black toward red and adds a small shake, so
    // breaking reads as actively chipping away at something rather than
    // just... waiting.
    private func drawBlockHighlight(around block: SIMD3<Int>, progress: Float, with encoder: MTLRenderCommandEncoder) {
        let origin = SIMD3<Float>(Float(block.x), Float(block.y), Float(block.z))
        let jitter: SIMD3<Float> = progress > 0
            ? SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)) * 0.01 * progress
            : SIMD3<Float>(repeating: 0)
        let color = Math.mix(SIMD3<Float>(0.05, 0.05, 0.05), SIMD3<Float>(0.95, 0.15, 0.05), progress)
        let vertices = BlockHighlight.buildVertices(blockOrigin: origin + jitter, color: color)
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared) else {
            return
        }
        encoder.setRenderPipelineState(highlightPipelineState)
        encoder.setDepthStencilState(waterDepthState) // test-but-don't-write, shared with the water pass
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
    }

    /// A flat billboard quad facing the camera, positioned `distance` away
    /// along `direction` — reuses the unlit/unfogged highlight pipeline (see
    /// vertex_highlight/fragment_highlight) rather than needing a dedicated
    /// shader, since a flat, un-shaded, distance-independent color is
    /// exactly what both already do. Shared by the sun and moon (see
    /// call site) — same geometry, just a different direction/size/color.
    private func drawCelestialBody(direction: SIMD3<Float>, distance: Float, size: Float, color: SIMD3<Float>, with encoder: MTLRenderCommandEncoder) {
        let worldUp = SIMD3<Float>(0, 1, 0)
        // Guards the near-vertical case (straight up/down) where
        // cross(worldUp, direction) would be near-zero and normalize would
        // blow up — arbitrary fixed right vector works fine there since the
        // quad's own orientation around a purely vertical axis is invisible.
        let right = length(cross(worldUp, direction)) > 0.001 ? normalize(cross(worldUp, direction)) : SIMD3<Float>(1, 0, 0)
        let up = cross(direction, right)

        let center = camera.position + direction * distance
        let half = size / 2
        let topLeft = center - right * half + up * half
        let topRight = center + right * half + up * half
        let bottomLeft = center - right * half - up * half
        let bottomRight = center + right * half - up * half

        let vertices = [
            Vertex(position: topLeft, normal: .zero, color: color),
            Vertex(position: bottomLeft, normal: .zero, color: color),
            Vertex(position: bottomRight, normal: .zero, color: color),
            Vertex(position: topLeft, normal: .zero, color: color),
            Vertex(position: bottomRight, normal: .zero, color: color),
            Vertex(position: topRight, normal: .zero, color: color),
        ]
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared) else {
            return
        }
        encoder.setRenderPipelineState(highlightPipelineState)
        encoder.setDepthStencilState(waterDepthState) // test-but-don't-write — see the call site's doc comment on why that's fine
        encoder.setCullMode(.none) // winding flips depending on position; not worth tracking, it's a flat billboard either way
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
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
