import Cocoa

/// Transient message near the crosshair — used for villager trade feedback
/// ("Need 5 Wood" / "Traded for 3 Planks"). Non-interactive, same as
/// CrosshairView/DebugOverlayView/BreakProgressView. Fades out on its own
/// after `duration` rather than needing an explicit hide call.
final class ToastView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let label = NSTextField(labelWithString: "")
    private let verticalOffset: CGFloat = 40 // above the crosshair
    private let fadeDuration: Float = 0.4
    private var remaining: Float = 0
    private var duration: Float = 2.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.sizeToFit()
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String, duration: Float = 2.0) {
        label.stringValue = "  \(text)  "
        label.sizeToFit()
        positionLabel()
        label.isHidden = false
        label.alphaValue = 1
        self.duration = duration
        remaining = duration
    }

    /// Ticked once per frame from Renderer.onFrameTick — counts the message
    /// down, then fades it over the last `fadeDuration` seconds.
    func update(deltaTime: Float) {
        guard remaining > 0 else { return }
        remaining -= deltaTime
        if remaining <= 0 {
            label.isHidden = true
        } else if remaining < fadeDuration {
            label.alphaValue = CGFloat(remaining / fadeDuration)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionLabel()
    }

    private func positionLabel() {
        label.frame = NSRect(
            x: bounds.midX - label.frame.width / 2,
            y: bounds.midY + verticalOffset,
            width: label.frame.width, height: label.frame.height
        )
    }
}
