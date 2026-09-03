import Cocoa

/// A small "+" drawn at the view's own center. Sized/positioned by
/// AppDelegate to always span the window and stay centered on resize; drawn
/// as a plain AppKit overlay rather than a second Metal pipeline since it's a
/// single static 2D shape with no reason to touch the 3D pipeline at all.
final class CrosshairView: NSView {
    override var isOpaque: Bool { false }

    // Never intercept mouse events — clicks/drags must reach the game view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let armLength: CGFloat = 9
        let gap: CGFloat = 3
        let thickness: CGFloat = 2

        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        // Horizontal arms
        context.fill(CGRect(x: center.x - armLength, y: center.y - thickness / 2, width: armLength - gap, height: thickness))
        context.fill(CGRect(x: center.x + gap, y: center.y - thickness / 2, width: armLength - gap, height: thickness))
        // Vertical arms
        context.fill(CGRect(x: center.x - thickness / 2, y: center.y - armLength, width: thickness, height: armLength - gap))
        context.fill(CGRect(x: center.x - thickness / 2, y: center.y + gap, width: thickness, height: armLength - gap))

        // A thin dark outline behind each arm would need extra draws; a
        // cheap alternative that keeps it visible on bright backgrounds too:
        // a soft dark dot underneath the crosshair's own footprint.
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
    }
}
