import Cocoa
import MetalKit
import QuartzCore

/// Owns the whole app lifecycle: the real title screen (MainMenuView) shown
/// before any world is loaded, and — once a world is picked or created —
/// building the entire game view hierarchy for it (startGame) and tearing it
/// back down on "Quit to Title" (quitToTitle) to return to the menu. Every
/// game-session object (renderer, mtkView, hotbar/inventory/etc. views,
/// gameControllerManager) is nil while at the title screen and only exists
/// between startGame and quitToTitle/quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mainMenuView: MainMenuView!

    var renderer: Renderer!
    var mtkView: RendererView!
    var inputController: InputController!
    var crosshairView: CrosshairView!
    var pauseMenuView: PauseMenuView!
    var settingsMenuView: SettingsMenuView!
    var debugOverlayView: DebugOverlayView!
    var hotbarView: HotbarView!
    var breakProgressView: BreakProgressView!
    var inventoryView: InventoryView!
    var mapView: MapView!
    var gameControllerManager: GameControllerManager!

    private var device: MTLDevice!

    // Global session settings (device performance / player preference, not
    // tied to any one world) — persisted only for the app's lifetime, and
    // reapplied to each fresh Renderer/mtkView a new game session gets (see
    // startGame), so quitting to title and picking another world doesn't
    // silently reset them.
    private var currentSensitivity: Float = 0.0025 // matches Camera's own default
    private var currentRenderDistance = 6 // matches ChunkManager's default loadRadius
    private var currentResolutionScale: Float = 1.0
    private var currentFPS = 60 // 0 means Uncapped — see setFPSCap
    private var currentPostEffect: PostEffect = .none
    // Drives draw() directly, bypassing MTKView's own CVDisplayLink-based
    // loop, while "Uncapped" is selected — see setFPSCap.
    private var uncappedDrawTimer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device

        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(contentRect: contentRect,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered,
                           defer: false)
        window.title = "Procedural Terrain"
        window.center()
        window.acceptsMouseMovedEvents = true

        mainMenuView = MainMenuView(frame: contentRect)
        mainMenuView.autoresizingMask = [.width, .height]
        mainMenuView.onPlayWorld = { [weak self] world in self?.startGame(world: world) }
        mainMenuView.onQuit = { NSApp.terminate(nil) }

        // If the window loses focus (Cmd-Tab, another app's window comes
        // forward) while playing, pause — otherwise the cursor would stay
        // captured (hidden, decoupled) over some other app's window. Set up
        // once here (not per game session) and just no-ops via the guard
        // whenever there's no active renderer (at the title screen).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let renderer = self.renderer, !renderer.isPaused else { return }
            self.showPauseMenu()
        }

        window.contentView = mainMenuView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mainMenuView)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Every break/place already saves asynchronously (see Renderer.persistSave),
    /// but the process can exit before that write actually runs — this blocks
    /// termination just long enough to flush the latest state synchronously.
    func applicationWillTerminate(_ notification: Notification) {
        renderer?.saveNow()
    }

    /// Builds the entire game view hierarchy for `world` and swaps it in as
    /// the window's content — mirrors quitToTitle's teardown exactly in
    /// reverse. Reapplies whatever global settings (sensitivity, render
    /// distance, resolution/FPS/post effect) an earlier session in this run
    /// left set, rather than resetting to defaults every time.
    private func startGame(world: WorldMeta) {
        WorldStore.touchLastPlayed(world.id)

        let contentRect = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1100, height: 750)
        inputController = InputController()

        mtkView = RendererView(frame: contentRect, device: device)
        mtkView.inputController = inputController
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearDepth = 1.0

        renderer = Renderer(device: device, inputController: inputController, world: world)
        mtkView.delegate = renderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        renderer.camera.lookSensitivity = currentSensitivity
        renderer.setRenderDistance(currentRenderDistance)
        renderer.setResolutionScale(currentResolutionScale)
        renderer.setPostEffect(currentPostEffect)
        setFPSCap(currentFPS)

        crosshairView = CrosshairView(frame: mtkView.bounds)
        crosshairView.autoresizingMask = [.width, .height]
        mtkView.addSubview(crosshairView)

        debugOverlayView = DebugOverlayView(frame: mtkView.bounds)
        debugOverlayView.autoresizingMask = [.width, .height]
        debugOverlayView.isHidden = true
        mtkView.addSubview(debugOverlayView)

        hotbarView = HotbarView(frame: mtkView.bounds, slotCount: Hotbar.hotbarSlotCount)
        hotbarView.autoresizingMask = [.width, .height]
        mtkView.addSubview(hotbarView)

        breakProgressView = BreakProgressView(frame: mtkView.bounds)
        breakProgressView.autoresizingMask = [.width, .height]
        mtkView.addSubview(breakProgressView)

        inventoryView = InventoryView(frame: mtkView.bounds, hotbar: renderer.hotbar)
        inventoryView.autoresizingMask = [.width, .height]
        inventoryView.isHidden = true
        mtkView.addSubview(inventoryView)

        mapView = MapView(frame: mtkView.bounds)
        mapView.autoresizingMask = [.width, .height]
        mapView.isHidden = true
        mtkView.addSubview(mapView)

        settingsMenuView = SettingsMenuView(frame: mtkView.bounds)
        settingsMenuView.autoresizingMask = [.width, .height]
        settingsMenuView.isHidden = true
        settingsMenuView.onBack = { [weak self] in self?.showPauseMenu() }
        settingsMenuView.onSensitivityChanged = { [weak self] value in
            guard let self else { return }
            self.currentSensitivity = value
            self.renderer.camera.lookSensitivity = value
        }
        settingsMenuView.onRenderDistanceChanged = { [weak self] value in
            self?.currentRenderDistance = value
            self?.renderer.setRenderDistance(value)
        }
        settingsMenuView.onGameModeChanged = { [weak self] mode in
            self?.renderer.setGameMode(mode)
        }
        settingsMenuView.onResolutionScaleChanged = { [weak self] scale in
            self?.currentResolutionScale = scale
            self?.renderer.setResolutionScale(scale)
        }
        settingsMenuView.onFPSChanged = { [weak self] fps in
            self?.setFPSCap(fps)
        }
        settingsMenuView.onPostEffectChanged = { [weak self] effect in
            self?.currentPostEffect = effect
            self?.renderer.setPostEffect(effect)
        }
        mtkView.addSubview(settingsMenuView)

        pauseMenuView = PauseMenuView(frame: mtkView.bounds)
        pauseMenuView.autoresizingMask = [.width, .height]
        pauseMenuView.isHidden = true
        pauseMenuView.onResume = { [weak self] in self?.resumeGame() }
        pauseMenuView.onSettings = { [weak self] in self?.showSettings() }
        pauseMenuView.onQuitToTitle = { [weak self] in self?.quitToTitle() }
        mtkView.addSubview(pauseMenuView)

        mtkView.onEscape = { [weak self] in self?.handleEscape() }
        mtkView.onToggleDebugOverlay = { [weak self] in self?.debugOverlayView.isHidden.toggle() }
        mtkView.onToggleInventory = { [weak self] in self?.toggleInventory() }
        mtkView.onToggleMap = { [weak self] in self?.toggleMap() }
        mtkView.onBreakBlock = { [weak self] in self?.attackOrBreak() }
        mtkView.onPlaceBlock = { [weak self] in self?.renderer.placeBlock() }
        renderer.onStatsUpdate = { [weak self] text in self?.debugOverlayView.setText(text) }
        renderer.onHotbarChanged = { [weak self] slots, selectedIndex in
            // HotbarView only ever shows the wieldable range — the rest is
            // inventory-only overflow, which InventoryView still gets in full.
            self?.hotbarView.update(slots: Array(slots.prefix(Hotbar.hotbarSlotCount)), selectedIndex: selectedIndex)
            self?.inventoryView.update(slots: slots, selectedIndex: selectedIndex)
        }
        renderer.onBreakProgressChanged = { [weak self] progress in self?.breakProgressView.setProgress(progress) }

        gameControllerManager = GameControllerManager(inputController: inputController, hotbar: renderer.hotbar, camera: renderer.camera)
        gameControllerManager.onPause = { [weak self] in self?.handleEscape() }
        gameControllerManager.onToggleInventory = { [weak self] in self?.toggleInventory() }
        gameControllerManager.onBreakBlock = { [weak self] in self?.attackOrBreak() }
        gameControllerManager.onPlaceBlock = { [weak self] in self?.renderer.placeBlock() }
        renderer.onFrameTick = { [weak self] deltaTime in self?.gameControllerManager.update(deltaTime: deltaTime) }

        window.title = "\(world.name) — WASD walk, mouse to look, Space jump, click to break/place, 1-9/0 hotbar, I inventory/craft, M map, Shift sprint, C camera, H debug"
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mtkView)

        renderer.isPaused = false
        mtkView.setCursorCaptured(true)
    }

    /// Tears the current game session down and returns to MainMenuView —
    /// mirrors startGame's setup exactly in reverse. Every game-session
    /// property goes back to nil, so nothing about this world lingers into
    /// whichever one gets picked next.
    private func quitToTitle() {
        renderer.saveNow()
        uncappedDrawTimer?.cancel()
        uncappedDrawTimer = nil
        // Stop anything that could still call draw() before draining —
        // otherwise waitForPendingFrames could race a fresh wait() against
        // its own drain.
        mtkView.isPaused = true
        mtkView.delegate = nil
        renderer.waitForPendingFrames()
        mtkView.setCursorCaptured(false) // restores the real cursor before this RendererView goes away

        renderer = nil
        mtkView = nil
        inputController = nil
        crosshairView = nil
        pauseMenuView = nil
        settingsMenuView = nil
        debugOverlayView = nil
        hotbarView = nil
        breakProgressView = nil
        inventoryView = nil
        mapView = nil
        gameControllerManager = nil

        window.title = "Procedural Terrain"
        window.contentView = mainMenuView
        mainMenuView.viewWillAppear()
        window.makeFirstResponder(mainMenuView)
    }

    private func resumeGame() {
        pauseMenuView.isHidden = true
        settingsMenuView.isHidden = true
        inventoryView.isHidden = true
        mapView.isHidden = true
        renderer.isPaused = false
        inputController.reset()
        gameControllerManager.resetHeldState()
        gameControllerManager.activeMenu = nil
        mtkView.setCursorCaptured(true)
    }

    private func showPauseMenu() {
        settingsMenuView.isHidden = true
        inventoryView.isHidden = true
        mapView.isHidden = true
        pauseMenuView.isHidden = false
        renderer.isPaused = true
        inputController.reset()
        gameControllerManager.resetHeldState()
        pauseMenuView.resetFocus()
        gameControllerManager.activeMenu = pauseMenuView
        mtkView.setCursorCaptured(false)
    }

    private func showSettings() {
        pauseMenuView.isHidden = true
        settingsMenuView.setInitialValues(
            sensitivity: renderer.camera.lookSensitivity,
            renderDistance: currentRenderDistance,
            gameMode: renderer.gameMode,
            resolutionScale: currentResolutionScale,
            fps: currentFPS,
            postEffect: renderer.postEffect
        )
        settingsMenuView.isHidden = false
        settingsMenuView.resetFocus()
        gameControllerManager.activeMenu = settingsMenuView
        // Already paused via the pause menu; nothing else to change.
    }

    /// Settings-menu hook. 0 means "Uncapped". MTKView's normal draw loop
    /// (isPaused = false) is driven by a CVDisplayLink tied to the display's
    /// actual hardware vsync signal — preferredFramesPerSecond can only
    /// throttle that DOWN by skipping callbacks, it can never push draws
    /// past the panel's own refresh rate (e.g. 60 on a 60Hz display) that
    /// way. To actually exceed it, Uncapped stops MTKView's own loop and
    /// drives draw() itself from a plain timer with no tie to vsync, while
    /// also disabling the Metal layer's present-time vsync wait so frames
    /// aren't throttled there either.
    private func setFPSCap(_ fps: Int) {
        currentFPS = fps
        uncappedDrawTimer?.cancel()
        uncappedDrawTimer = nil

        guard fps != 0 else {
            (mtkView.layer as? CAMetalLayer)?.displaySyncEnabled = false
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = false
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1), leeway: .nanoseconds(0))
            timer.setEventHandler { [weak self] in self?.mtkView.draw() }
            timer.resume()
            uncappedDrawTimer = timer
            return
        }

        (mtkView.layer as? CAMetalLayer)?.displaySyncEnabled = true
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = fps
    }

    /// I toggles the inventory screen. Ignored while the pause/settings
    /// screens are up, or the map is — those already own "paused with cursor
    /// released," and inventory shouldn't fight them for it.
    private func toggleInventory() {
        guard pauseMenuView.isHidden, settingsMenuView.isHidden, mapView.isHidden else { return }
        if inventoryView.isHidden {
            inventoryView.isHidden = false
            renderer.isPaused = true
            inputController.reset()
            gameControllerManager.resetHeldState()
            inventoryView.resetFocus()
            gameControllerManager.activeMenu = inventoryView
            mtkView.setCursorCaptured(false)
        } else {
            inventoryView.isHidden = true
            renderer.isPaused = false
            inputController.reset()
            gameControllerManager.resetHeldState()
            gameControllerManager.activeMenu = nil
            mtkView.setCursorCaptured(true)
        }
    }

    /// M toggles the map screen — same "ignored while another full-screen
    /// overlay owns pause" guard as toggleInventory. Opening is further
    /// gated on actually having crafted a Map (see VoxelType.map): without
    /// one, M is simply a no-op rather than showing an empty/placeholder
    /// screen.
    private func toggleMap() {
        guard pauseMenuView.isHidden, settingsMenuView.isHidden, inventoryView.isHidden else { return }
        if mapView.isHidden {
            guard renderer.hotbar.count(of: .map) > 0 else { return }
            let position = renderer.camera.position
            mapView.setInitialValues(
                centerX: Int(position.x.rounded(.down)),
                centerZ: Int(position.z.rounded(.down)),
                yaw: renderer.camera.yaw,
                sampleColor: renderer.terrainColor
            )
            mapView.isHidden = false
            renderer.isPaused = true
            inputController.reset()
            gameControllerManager.resetHeldState()
            mapView.resetFocus()
            gameControllerManager.activeMenu = mapView
            mtkView.setCursorCaptured(false)
        } else {
            mapView.isHidden = true
            renderer.isPaused = false
            inputController.reset()
            gameControllerManager.resetHeldState()
            gameControllerManager.activeMenu = nil
            mtkView.setCursorCaptured(true)
        }
    }

    /// Left click / controller break-button: attacking an animal takes
    /// priority over breaking whatever block is behind it — mirrors the
    /// usual "same button hits whatever you're looking at" convention.
    private func attackOrBreak() {
        guard !renderer.attackTargetedAnimal() else { return }
        renderer.breakTargetedBlock()
    }

    private func handleEscape() {
        if !mapView.isHidden {
            toggleMap()
        } else if !inventoryView.isHidden {
            toggleInventory()
        } else if !settingsMenuView.isHidden {
            showPauseMenu()
        } else if !pauseMenuView.isHidden {
            resumeGame()
        } else {
            showPauseMenu()
        }
    }
}
