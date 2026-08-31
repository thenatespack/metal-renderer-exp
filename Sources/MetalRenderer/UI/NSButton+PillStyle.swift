import Cocoa

extension NSButton {
    /// Styles this button as a solid white rounded pill with black text.
    /// Deliberately doesn't rely on the native bezel's own fill: NSButton's
    /// .rounded bezelStyle intermittently fails to paint its background once
    /// the view is layer-backed (wantsLayer = true, needed here for the
    /// focus-highlight border every menu toggles via layer.borderWidth),
    /// leaving a see-through button with only its label visible. Painting an
    /// explicit layer background underneath guarantees a solid white fill
    /// either way, and attributedTitle guarantees black text regardless of
    /// what the (possibly-broken) bezel would have drawn.
    func stylePillButton() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }
}
