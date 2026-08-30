/// macOS virtual key codes for the keys the player controller cares about.
enum KeyCode {
    static let w: UInt16 = 13
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let space: UInt16 = 49
    static let c: UInt16 = 8
    static let h: UInt16 = 4
    static let i: UInt16 = 34
    static let escape: UInt16 = 53
    // Standard ANSI number-row codes — not sequential, so listed explicitly.
    // Order matches the hotbar's 10 slots: 1...9, then 0.
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] // 1...9, 0
}

/// Tracks currently-held keys, modifier state, and accumulated mouse-drag deltas.
/// Fed by RendererView's event overrides; consumed once per frame by PlayerController.
final class InputController {
    private(set) var pressedKeys = Set<UInt16>()
    var shiftPressed = false
    /// Held state of the left mouse button — survival-mode breaking needs
    /// "still holding," not just the discrete mouseDown click creative mode
    /// uses, so this is tracked continuously rather than as an edge.
    private(set) var isLeftMouseDown = false

    private var accumDX: Float = 0
    private var accumDY: Float = 0

    // Keys that had a keyDown edge (not held-repeat) since the last consume —
    // for one-shot toggles like third-person, where "still held" shouldn't
    // keep re-firing every frame.
    private var pressedEdges: Set<UInt16> = []

    func keyDown(_ code: UInt16) {
        pressedKeys.insert(code)
        pressedEdges.insert(code)
    }

    func keyUp(_ code: UInt16) {
        pressedKeys.remove(code)
    }

    func consumeKeyPress(_ code: UInt16) -> Bool {
        pressedEdges.remove(code) != nil
    }

    func setLeftMouseDown(_ down: Bool) {
        isLeftMouseDown = down
    }

    func addMouseDelta(dx: Float, dy: Float) {
        accumDX += dx
        accumDY += dy
    }

    func consumeMouseDelta() -> (dx: Float, dy: Float) {
        defer { accumDX = 0; accumDY = 0 }
        return (accumDX, accumDY)
    }

    /// Clears all held/edge/accumulated state. Called whenever a menu opens
    /// or closes over the game — without this, a key held down when the menu
    /// opens can look "stuck" (its keyUp goes to the menu instead, since
    /// first responder moves away from the game view), and a one-shot edge
    /// like the third-person toggle could fire on the frame gameplay resumes
    /// even though the actual press happened while paused.
    func reset() {
        pressedKeys.removeAll()
        pressedEdges.removeAll()
        shiftPressed = false
        isLeftMouseDown = false
        accumDX = 0
        accumDY = 0
    }
}
