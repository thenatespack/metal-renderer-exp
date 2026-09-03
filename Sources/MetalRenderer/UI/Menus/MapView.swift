import Cocoa
import simd

/// Full-screen top-down terrain overview, toggled with M — only usable once
/// the player has crafted a Map (see VoxelType.map, AppDelegate.toggleMap).
/// Shows the natural landscape around the player (not live/explored-only:
/// TerrainGenerator is a pure function of coordinates, so this samples it
/// directly, same as a real paper map showing surveyed terrain rather than
/// only ground you've personally walked) plus a marker for position/facing.
///
/// The sample grid is captured once in setInitialValues rather than redrawn
/// live — the game is paused while this is up (see AppDelegate.toggleMap),
/// same as Settings/Inventory, so the player's position can't change out
/// from under it anyway.
///
/// Full-bounds and hit-intercepting (no hitTest override) like
/// PauseMenuView/InventoryView, so it blocks game input while open.
final class MapView: NSView, ControllerMenuNavigable {
    // Real-world span (blocks) the map covers, and how many cells sample
    // that span per side — coarser than 1:1 so a single crafted Map shows a
    // wide-ish area without needing thousands of terrain samples.
    private let rangeBlocks = 192
    private let gridResolution = 96

    private var cellColors: [SIMD3<Float>] = []
    private var playerYaw: Float = 0
    private var mapImage: CGImage?

    private let mapDisplaySize: CGFloat = 480

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setInitialValues(centerX: Int, centerZ: Int, yaw: Float, sampleColor: (Int, Int) -> SIMD3<Float>) {
        playerYaw = yaw

        let half = rangeBlocks / 2
        let step = max(1, rangeBlocks / gridResolution)
        var colors: [SIMD3<Float>] = []
        colors.reserveCapacity(gridResolution * gridResolution)
        // Row 0 is the northmost (most negative z) edge, matching how the
        // image gets built top-down below.
        for row in 0..<gridResolution {
            let z = centerZ - half + row * step
            for col in 0..<gridResolution {
                let x = centerX - half + col * step
                colors.append(sampleColor(x, z))
            }
        }
        cellColors = colors
        mapImage = Self.makeImage(colors: colors, side: gridResolution)
        needsDisplay = true
    }

    private static func makeImage(colors: [SIMD3<Float>], side: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for (index, color) in colors.enumerated() {
            pixels[index * 4 + 0] = UInt8(clamping: Int(color.x * 255))
            pixels[index * 4 + 1] = UInt8(clamping: Int(color.y * 255))
            pixels[index * 4 + 2] = UInt8(clamping: Int(color.z * 255))
            pixels[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: ControllerMenuNavigable — nothing to navigate, just here so
    // GameControllerManager's Circle/Options "back" path (onPause ->
    // AppDelegate.handleEscape) works while this is the active menu.

    func resetFocus() {}
    func moveFocus(by delta: Int) {}
    func adjustFocused(by delta: Int) {}
    func activateFocused() {}

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let title = "Map" as NSString
        let titleSize = title.size(withAttributes: titleAttrs)
        let mapRect = CGRect(x: bounds.midX - mapDisplaySize / 2, y: bounds.midY - mapDisplaySize / 2, width: mapDisplaySize, height: mapDisplaySize)
        title.draw(at: NSPoint(x: bounds.midX - titleSize.width / 2, y: mapRect.maxY + 20), withAttributes: titleAttrs)

        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(mapRect.insetBy(dx: -6, dy: -6))

        if let mapImage {
            context.saveGState()
            context.interpolationQuality = .none // crisp pixel blocks, matching the game's own blocky look
            context.draw(mapImage, in: mapRect)
            context.restoreGState()
        }

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(2)
        context.stroke(mapRect)

        drawPlayerMarker(center: CGPoint(x: mapRect.midX, y: mapRect.midY), context: context)

        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let hint = "M or Esc to close" as NSString
        let hintSize = hint.size(withAttributes: hintAttrs)
        hint.draw(at: NSPoint(x: bounds.midX - hintSize.width / 2, y: mapRect.minY - 30), withAttributes: hintAttrs)
    }

    /// A small triangle pointing along the player's facing — Camera.front is
    /// (sin(yaw), _, -cos(yaw)) at pitch 0, so yaw 0 (facing -z) points "up"
    /// on screen here (screen +y = world -z, i.e. north-up), matching how
    /// the sample grid above lays row 0 out at the most-negative z.
    private func drawPlayerMarker(center: CGPoint, context: CGContext) {
        let dirX = CGFloat(sin(playerYaw))
        let dirY = CGFloat(cos(playerYaw))
        let perpX = -dirY
        let perpY = dirX

        let tipLength: CGFloat = 12
        let backLength: CGFloat = 7
        let width: CGFloat = 7

        let tip = CGPoint(x: center.x + dirX * tipLength, y: center.y + dirY * tipLength)
        let left = CGPoint(x: center.x - dirX * backLength + perpX * width, y: center.y - dirY * backLength + perpY * width)
        let right = CGPoint(x: center.x - dirX * backLength - perpX * width, y: center.y - dirY * backLength - perpY * width)

        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()

        context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.2, alpha: 1).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
    }
}
