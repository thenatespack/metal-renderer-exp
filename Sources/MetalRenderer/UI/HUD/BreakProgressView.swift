import Cocoa

/// Thin fill bar just below the crosshair, shown only while actively
/// breaking a block in survival mode (see Renderer.updateSurvivalBreaking).
/// Non-interactive, same as CrosshairView/DebugOverlayView.
final class BreakProgressView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let barWidth: CGFloat = 60
    private let barHeight: CGFloat = 6
    private let verticalOffset: CGFloat = -26 // below the crosshair

    private var progress: Float = 0

    func setProgress(_ value: Float) {
        let clamped = max(0, min(1, value))
        guard clamped != progress else { return }
        progress = clamped
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard progress > 0, let context = NSGraphicsContext.current?.cgContext else { return }

        let rect = CGRect(
            x: bounds.midX - barWidth / 2,
            y: bounds.midY + verticalOffset,
            width: barWidth, height: barHeight
        )

        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(rect)

        let fillColor = NSColor(calibratedRed: CGFloat(0.9), green: CGFloat(0.9 - 0.7 * CGFloat(progress)), blue: 0.15, alpha: 1)
        context.setFillColor(fillColor.cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(progress), height: rect.height))

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
    }
}
