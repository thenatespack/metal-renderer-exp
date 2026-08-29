import Cocoa

/// Row of block-type swatches, bottom-center. Selection is keyboard-only (1
/// through however many items there are) — non-interactive to mouse clicks,
/// same as CrosshairView/DebugOverlayView, to keep hit-testing simple.
final class HotbarView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let colors: [NSColor]
    private var selectedIndex = 0

    private let slotSize: CGFloat = 40
    private let slotSpacing: CGFloat = 6
    private let bottomInset: CGFloat = 24

    init(frame frameRect: NSRect, colors: [NSColor]) {
        self.colors = colors
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelectedIndex(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !colors.isEmpty else { return }

        let totalWidth = CGFloat(colors.count) * slotSize + CGFloat(colors.count - 1) * slotSpacing
        let startX = bounds.midX - totalWidth / 2

        for (index, color) in colors.enumerated() {
            let rect = CGRect(x: startX + CGFloat(index) * (slotSize + slotSpacing), y: bottomInset, width: slotSize, height: slotSize)

            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.fill(rect.insetBy(dx: -4, dy: -4))

            context.setFillColor(color.cgColor)
            context.fill(rect)

            if index == selectedIndex {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: -4, dy: -4))
            }
        }
    }
}
