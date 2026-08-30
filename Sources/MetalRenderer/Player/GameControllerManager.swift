import GameController

/// PlayStation (DualShock/DualSense) controller support, via the generic
/// GCExtendedGamepad profile rather than any PS-specific class — macOS maps
/// Cross/Circle/Square/Triangle onto buttonA/B/X/Y automatically, so this
/// works without ever naming a PlayStation button directly, and picks up
/// Xbox/other MFi controllers the same way for free.
///
/// Sticks and held buttons are translated into the *same* synthetic key
/// events keyboard input already produces (see InputController), wherever a
/// direct keyboard equivalent exists — so all of PlayerController's
/// movement/look/swim/jump logic runs completely unchanged regardless of
/// input source, instead of needing a second parallel implementation. UI
/// actions (pause, inventory) that don't have a keyboard analogue exposed
/// here go through their own closures, mirroring RendererView's onEscape/
/// onToggleInventory.
///
/// Mapping:
///   Left stick    — move (WASD-equivalent)
///   Right stick   — look
///   Cross (A)     — jump / swim up
///   Circle (B), Options (Menu) — pause / back
///   Square (X)    — toggle inventory
///   Triangle (Y)  — toggle third-person camera
///   L1 / R1       — cycle hotbar selection
///   L2            — place block
///   R2            — break block (held, for survival's timed breaking)
///   L3 (left stick click) — sprint
///
/// Whenever `activeMenu` is set (see AppDelegate — one of PauseMenuView,
/// SettingsMenuView), the D-pad and Cross switch roles entirely: D-pad
/// up/down moves focus, left/right adjusts the focused control, and Cross
/// activates it instead of jumping. Movement/look sticks keep working
/// underneath (harmlessly, since PlayerController.update is skipped while
/// paused) but the D-pad is never used for movement, so there's no ambiguity
/// about which mode it's in.
final class GameControllerManager {
    private let inputController: InputController
    private let hotbar: Hotbar
    private let camera: Camera

    var onPause: (() -> Void)?
    var onToggleInventory: (() -> Void)?
    var onBreakBlock: (() -> Void)?
    var onPlaceBlock: (() -> Void)?
    /// Set by AppDelegate whenever a navigable menu is on screen; nil during
    /// normal gameplay (and while the inventory screen, which has nothing to
    /// navigate, is up).
    var activeMenu: ControllerMenuNavigable?

    private var controller: GCController?
    private let stickDeadzone: Float = 0.2
    private let lookRadiansPerSecond: Float = 3.0
    private var heldSynthKeys: Set<UInt16> = []

    init(inputController: InputController, hotbar: Hotbar, camera: Camera) {
        self.inputController = inputController
        self.hotbar = hotbar
        self.camera = camera

        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] notification in
            self?.handleConnect(notification)
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] notification in
            self?.handleDisconnect(notification)
        }

        controller = GCController.controllers().first
        configureButtons()
    }

    private func handleConnect(_ notification: Notification) {
        guard controller == nil, let connected = notification.object as? GCController else { return }
        controller = connected
        configureButtons()
    }

    private func handleDisconnect(_ notification: Notification) {
        guard let disconnected = notification.object as? GCController, disconnected === controller else { return }
        releaseAllSynthInput()
        controller = GCController.controllers().first
        configureButtons()
    }

    private func configureButtons() {
        guard let gamepad = controller?.extendedGamepad else { return }

        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self else { return }
            if let menu = self.activeMenu {
                if pressed { menu.activateFocused() }
            } else {
                self.setSynthKey(KeyCode.space, pressed: pressed)
            }
        }
        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.activeMenu?.moveFocus(by: -1)
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.activeMenu?.moveFocus(by: 1)
        }
        gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.activeMenu?.adjustFocused(by: -1)
        }
        gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.activeMenu?.adjustFocused(by: 1)
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onPause?()
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onPause?()
        }
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onToggleInventory?()
        }
        // Third person has no dedicated closure — it's an edge-triggered key
        // (KeyCode.c) PlayerController already consumes each frame, same as
        // a keyboard tap, so just synthesize a quick down+up.
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed, let self else { return }
            self.inputController.keyDown(KeyCode.c)
            self.inputController.keyUp(KeyCode.c)
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.hotbar.cycle(by: -1)
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.hotbar.cycle(by: 1)
        }
        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onPlaceBlock?()
        }
        // Mirrors RendererView's mouseDown/mouseUp exactly: the discrete
        // edge fires creative's instant break, while the continuous held
        // state (setLeftMouseDown) drives survival's timed breaking, which
        // polls it every frame rather than reacting to an event.
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.inputController.setLeftMouseDown(pressed)
            guard pressed else { return }
            self?.onBreakBlock?()
        }
        gamepad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.inputController.shiftPressed = pressed
        }
    }

    private func setSynthKey(_ code: UInt16, pressed: Bool) {
        if pressed {
            guard !heldSynthKeys.contains(code) else { return }
            heldSynthKeys.insert(code)
            inputController.keyDown(code)
        } else {
            guard heldSynthKeys.remove(code) != nil else { return }
            inputController.keyUp(code)
        }
    }

    /// Disconnecting mid-move/mid-break shouldn't leave the player walking
    /// or breaking forever — release everything this controller was holding.
    private func releaseAllSynthInput() {
        for code in heldSynthKeys {
            inputController.keyUp(code)
        }
        heldSynthKeys.removeAll()
        inputController.setLeftMouseDown(false)
        inputController.shiftPressed = false
    }

    /// Call alongside every InputController.reset() (every pause/menu
    /// transition — see AppDelegate). reset() clears InputController's state
    /// directly, out from under our own heldSynthKeys bookkeeping; without
    /// this, a still-deflected stick at the moment of pausing would look
    /// "already pressed" to setSynthKey next frame and silently never
    /// re-send the keyDown that InputController just lost, leaving movement
    /// stuck off until the stick is released and re-pushed.
    func resetHeldState() {
        heldSynthKeys.removeAll()
    }

    /// Called every frame (see Renderer.onFrameTick) — sticks are continuous
    /// analog state, not discrete events like buttons, so they need polling
    /// rather than a handler.
    func update(deltaTime: Float) {
        guard let gamepad = controller?.extendedGamepad else { return }
        // Movement/look sticks are gameplay-only — a menu being up means
        // we're paused anyway, and skipping this avoids relying on that
        // rather than risking a stray frame of movement during a transition.
        guard activeMenu == nil else { return }

        let left = gamepad.leftThumbstick
        setSynthKey(KeyCode.w, pressed: left.yAxis.value > stickDeadzone)
        setSynthKey(KeyCode.s, pressed: left.yAxis.value < -stickDeadzone)
        setSynthKey(KeyCode.d, pressed: left.xAxis.value > stickDeadzone)
        setSynthKey(KeyCode.a, pressed: left.xAxis.value < -stickDeadzone)

        let right = gamepad.rightThumbstick
        let rx = abs(right.xAxis.value) > stickDeadzone ? right.xAxis.value : 0
        let ry = abs(right.yAxis.value) > stickDeadzone ? right.yAxis.value : 0
        guard rx != 0 || ry != 0 else { return }

        // Sticks give a continuous look *rate*, not a one-shot pixel delta
        // like a mouse move — converted here into an equivalent synthetic
        // mouse delta (inverting the sensitivity multiply PlayerController
        // applies) so it flows through the exact same consume-once-per-frame
        // path mouse look already uses, deadzone/clamping included.
        let sensitivity = max(camera.lookSensitivity, 0.0001)
        let dx = rx * lookRadiansPerSecond * deltaTime / sensitivity
        let dy = -ry * lookRadiansPerSecond * deltaTime / sensitivity
        inputController.addMouseDelta(dx: dx, dy: dy)
    }
}
