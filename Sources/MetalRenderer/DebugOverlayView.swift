import Cocoa

/// Top-left stats readout, toggled by H. Non-interactive (hitTest returns
/// nil, same as CrosshairView) so it never blocks input to the game.
final class DebugOverlayView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let labelWidth: CGFloat = 260
    private let labelHeight: CGFloat = 100
    private let inset: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
        positionLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionLabel()
    }

    private func positionLabel() {
        label.frame = NSRect(x: inset, y: bounds.height - labelHeight - inset, width: labelWidth, height: labelHeight)
    }

    func setText(_ text: String) {
        label.stringValue = text
    }
}
