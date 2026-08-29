import Cocoa
import MetalKit

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

    private var gameHasStarted = false
    private var currentRenderDistance = 6 // must match ChunkManager's default loadRadius

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(contentRect: contentRect,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered,
                           defer: false)
        window.title = "Procedural Terrain — WASD walk, mouse to look, Space jump, click to break/place, 1-7 hotbar, Shift sprint, C camera, H debug"
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

        let hotbarColors = renderer.hotbar.items.map { item -> NSColor in
            let c = item.color
            return NSColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
        hotbarView = HotbarView(frame: mtkView.bounds, colors: hotbarColors)
        hotbarView.autoresizingMask = [.width, .height]
        mtkView.addSubview(hotbarView)

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
        mtkView.onBreakBlock = { [weak self] in self?.renderer.breakTargetedBlock() }
        mtkView.onPlaceBlock = { [weak self] in self?.renderer.placeBlock() }
        renderer.onStatsUpdate = { [weak self] text in self?.debugOverlayView.setText(text) }
        renderer.onHotbarSelectionChanged = { [weak self] index in self?.hotbarView.setSelectedIndex(index) }

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
        renderer.isPaused = false
        inputController.reset()
        mtkView.setCursorCaptured(true)
    }

    private func showPauseMenu() {
        settingsMenuView.isHidden = true
        pauseMenuView.playButtonTitle = gameHasStarted ? "Resume" : "Play"
        pauseMenuView.isHidden = false
        renderer.isPaused = true
        inputController.reset()
        mtkView.setCursorCaptured(false)
    }

    private func showSettings() {
        pauseMenuView.isHidden = true
        settingsMenuView.setInitialValues(sensitivity: renderer.camera.lookSensitivity, renderDistance: currentRenderDistance)
        settingsMenuView.isHidden = false
        // Already paused via the pause menu; nothing else to change.
    }

    private func handleEscape() {
        if !settingsMenuView.isHidden {
            showPauseMenu()
        } else if !pauseMenuView.isHidden {
            resumeGame()
        } else {
            showPauseMenu()
        }
    }
}
