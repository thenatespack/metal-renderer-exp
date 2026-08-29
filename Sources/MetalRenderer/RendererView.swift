import MetalKit
import CoreGraphics

/// MTKView that forwards keyboard and mouse-look input to an InputController.
/// Escape and H are UI concerns (pause menu, debug overlay) rather than
/// gameplay, so they're intercepted here directly instead of flowing through
/// InputController/PlayerController.
final class RendererView: MTKView {
    var inputController: InputController!
    var onEscape: (() -> Void)?
    var onToggleDebugOverlay: (() -> Void)?
    var onBreakBlock: (() -> Void)?
    var onPlaceBlock: (() -> Void)?

    private(set) var isCursorCaptured = false

    override var acceptsFirstResponder: Bool { true }

    /// Hides the cursor and decouples it from screen position (so it can't
    /// wander off or hit a screen edge) while still delivering raw movement
    /// deltas via mouseMoved — the standard FPS mouse-look technique. Call
    /// with `false` whenever a menu needs real clicks/drags (its cursor is
    /// restored at wherever it physically is once re-associated).
    func setCursorCaptured(_ captured: Bool) {
        guard captured != isCursorCaptured else { return }
        isCursorCaptured = captured
        if captured {
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }

        switch event.keyCode {
        case KeyCode.escape:
            onEscape?()
            return
        case KeyCode.h:
            onToggleDebugOverlay?()
            return
        default:
            break
        }

        inputController.keyDown(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        inputController.keyUp(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        inputController.shiftPressed = event.modifierFlags.contains(.shift)
        super.flagsChanged(with: event)
    }

    // mouseMoved fires continuously while the cursor is captured (no button
    // held); mouseDragged covers the uncaptured click-and-drag fallback.
    // Both just forward the raw delta the same way.
    override func mouseMoved(with event: NSEvent) {
        inputController.addMouseDelta(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func mouseDragged(with event: NSEvent) {
        inputController.addMouseDelta(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func rightMouseDragged(with event: NSEvent) {
        inputController.addMouseDelta(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    // Left click breaks, right click places — a menu overlay sits above this
    // view and intercepts hit-testing whenever one is open (see PauseMenuView),
    // so these only ever fire during actual gameplay.
    override func mouseDown(with event: NSEvent) {
        onBreakBlock?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onPlaceBlock?()
    }
}
