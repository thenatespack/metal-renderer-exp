import Cocoa

/// Row of inventory slots, bottom-center. Empty slots (survival, before
/// anything's been picked up) draw as a bare dark square; filled ones show
/// their block color and, when finite, a count. Selection is keyboard-only —
/// non-interactive to mouse clicks, same as CrosshairView/DebugOverlayView.
final class HotbarView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var slots: [HotbarSlot]
    private var selectedIndex = 0

    private let slotSize: CGFloat = 40
    private let slotSpacing: CGFloat = 6
    private let bottomInset: CGFloat = 24

    init(frame frameRect: NSRect, slotCount: Int) {
        slots = Array(repeating: HotbarSlot(type: nil, count: 0), count: slotCount)
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(slots: [HotbarSlot], selectedIndex: Int) {
        self.slots = slots
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !slots.isEmpty else { return }

        let totalWidth = CGFloat(slots.count) * slotSize + CGFloat(slots.count - 1) * slotSpacing
        let startX = bounds.midX - totalWidth / 2

        for (index, slot) in slots.enumerated() {
            let rect = CGRect(x: startX + CGFloat(index) * (slotSize + slotSpacing), y: bottomInset, width: slotSize, height: slotSize)

            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.fill(rect.insetBy(dx: -4, dy: -4))

            if let type = slot.type {
                let c = type.color
                context.setFillColor(NSColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1).cgColor)
                context.fill(rect)

                if slot.count > 1 {
                    let text = "\(slot.count)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.boldSystemFont(ofSize: 12),
                        .foregroundColor: NSColor.white,
                    ]
                    let size = text.size(withAttributes: attrs)
                    text.draw(at: NSPoint(x: rect.maxX - size.width - 2, y: rect.minY + 1), withAttributes: attrs)
                }
            }

            if index == selectedIndex {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: -4, dy: -4))
            }
        }

        // Name of whatever's currently selected, centered above the row.
        let labelText = (slots[selectedIndex].type?.displayName ?? "Empty") as NSString
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = labelText.size(withAttributes: labelAttrs)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: 0)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        labelText.draw(at: NSPoint(x: bounds.midX - labelSize.width / 2, y: bottomInset + slotSize + 10), withAttributes: labelAttrs)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
