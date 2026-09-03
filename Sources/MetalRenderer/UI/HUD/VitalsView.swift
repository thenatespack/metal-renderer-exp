import Cocoa

/// Two proportional fill bars (health, hunger) centered above the hotbar —
/// same fill-bar shape as BreakProgressView, just always visible in survival
/// instead of only while breaking. Hidden entirely in creative (see
/// AppDelegate), matching how creative already has no break-progress either.
final class VitalsView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var health: Int = 1
    private var maxHealth: Int = 1
    private var hunger: Int = 1
    private var maxHunger: Int = 1

    private let barWidth: CGFloat = 160
    private let barHeight: CGFloat = 10
    private let barSpacing: CGFloat = 6
    // Sits just above HotbarView's own slot row + name label (bottomInset 24
    // + slotSize 40 + label ~24) — see HotbarView.
    private let hungerBottomInset: CGFloat = 96

    func update(health: Int, maxHealth: Int, hunger: Int, maxHunger: Int) {
        guard health != self.health || maxHealth != self.maxHealth || hunger != self.hunger || maxHunger != self.maxHunger else { return }
        self.health = health
        self.maxHealth = maxHealth
        self.hunger = hunger
        self.maxHunger = maxHunger
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let hungerRect = CGRect(x: bounds.midX - barWidth / 2, y: hungerBottomInset, width: barWidth, height: barHeight)
        let healthRect = hungerRect.offsetBy(dx: 0, dy: barHeight + barSpacing)

        drawBar(healthRect, fraction: Float(health) / Float(max(1, maxHealth)), color: NSColor(calibratedRed: 0.85, green: 0.2, blue: 0.2, alpha: 1), context: context)
        drawBar(hungerRect, fraction: Float(hunger) / Float(max(1, maxHunger)), color: NSColor(calibratedRed: 0.75, green: 0.5, blue: 0.15, alpha: 1), context: context)
    }

    private func drawBar(_ rect: CGRect, fraction: Float, color: NSColor, context: CGContext) {
        let clamped = max(0, min(1, fraction))

        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(rect)

        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(clamped), height: rect.height))

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
    }
}
