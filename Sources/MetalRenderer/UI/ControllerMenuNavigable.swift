/// Implemented by menu views that GameControllerManager can drive with the
/// D-pad + Cross, alongside their existing mouse-click interaction — the two
/// input paths call the same underlying action methods either way, so
/// there's no separate "controller version" of what a menu does.
protocol ControllerMenuNavigable: AnyObject {
    /// D-pad up/down: -1 moves focus back, +1 forward, wrapping around.
    func moveFocus(by delta: Int)
    /// D-pad left/right: adjusts the focused control's value in place
    /// (slider, segmented control) — a no-op for a plain button.
    func adjustFocused(by delta: Int)
    /// Cross: activates the focused control the same way a click would.
    func activateFocused()
    /// Called whenever this menu becomes the active one, so focus starts
    /// somewhere predictable instead of wherever it was last left.
    func resetFocus()
}
