import Cocoa
import MetalKit
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
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
    var gameControllerManager: GameControllerManager!

    private var gameHasStarted = false
    private var currentRenderDistance = 6 // must match ChunkManager's default loadRadius
    private var currentResolutionScale: Float = 1.0
    private var currentFPS = 60 // must match mtkView.preferredFramesPerSecond below; 0 means uncapped
    // Drives draw() directly, bypassing MTKView's own CVDisplayLink-based
    // loop, while "Uncapped" is selected — see setFPSCap.
    private var uncappedDrawTimer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(contentRect: contentRect,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered,
                           defer: false)
        window.title = "Procedural Terrain — WASD walk, mouse to look, Space jump, click to break/place, 1-9 hotbar, I inventory/craft, Shift sprint, C camera, H debug"
        window.center()
        window.acceptsMouseMovedEvents = true

        inputController = InputController()

        mtkView = RendererView(frame: contentRect, device: device)
        mtkView.inputController = inputController
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearDepth = 1.0
        mtkView.preferredFramesPerSecond = 60

        renderer = Renderer(device: device, inputController: inputController)
        mtkView.delegate = renderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)

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

        settingsMenuView = SettingsMenuView(frame: mtkView.bounds)
        settingsMenuView.autoresizingMask = [.width, .height]
        settingsMenuView.isHidden = true
        settingsMenuView.onBack = { [weak self] in self?.showPauseMenu() }
        settingsMenuView.onSensitivityChanged = { [weak self] value in
            self?.renderer.camera.lookSensitivity = value
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
            self?.renderer.setPostEffect(effect)
        }
        mtkView.addSubview(settingsMenuView)

        pauseMenuView = PauseMenuView(frame: mtkView.bounds)
        pauseMenuView.autoresizingMask = [.width, .height]
        pauseMenuView.onPlay = { [weak self] in self?.resumeGame() }
        pauseMenuView.onSettings = { [weak self] in self?.showSettings() }
        pauseMenuView.onQuit = { NSApp.terminate(nil) }
        mtkView.addSubview(pauseMenuView)

        // Start paused on the main menu — chunk streaming still runs in the
        // background (see Renderer.isPaused), so the world around spawn is
        // already loaded by the time Play is pressed.
        renderer.isPaused = true

        mtkView.onEscape = { [weak self] in self?.handleEscape() }
        mtkView.onToggleDebugOverlay = { [weak self] in self?.debugOverlayView.isHidden.toggle() }
        mtkView.onToggleInventory = { [weak self] in self?.toggleInventory() }
        mtkView.onBreakBlock = { [weak self] in self?.renderer.breakTargetedBlock() }
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
        gameControllerManager.onBreakBlock = { [weak self] in self?.renderer.breakTargetedBlock() }
        gameControllerManager.onPlaceBlock = { [weak self] in self?.renderer.placeBlock() }
        renderer.onFrameTick = { [weak self] deltaTime in self?.gameControllerManager.update(deltaTime: deltaTime) }

        // If the window loses focus (Cmd-Tab, another app's window comes
        // forward) while playing, pause — otherwise the cursor would stay
        // captured (hidden, decoupled) over some other app's window.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, !self.renderer.isPaused else { return }
            self.showPauseMenu()
        }

        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mtkView)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func resumeGame() {
        gameHasStarted = true
        pauseMenuView.isHidden = true
        settingsMenuView.isHidden = true
        inventoryView.isHidden = true
        renderer.isPaused = false
        inputController.reset()
        gameControllerManager.resetHeldState()
        gameControllerManager.activeMenu = nil
        mtkView.setCursorCaptured(true)
    }

    private func showPauseMenu() {
        settingsMenuView.isHidden = true
        inventoryView.isHidden = true
        pauseMenuView.playButtonTitle = gameHasStarted ? "Resume" : "Play"
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
    /// screens are up (including at the main menu, before Play) — those
    /// already own "paused with cursor released," and inventory shouldn't
    /// fight them for it.
    private func toggleInventory() {
        guard pauseMenuView.isHidden, settingsMenuView.isHidden else { return }
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

    private func handleEscape() {
        if !inventoryView.isHidden {
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
