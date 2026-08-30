import Cocoa

/// Doubles as the main menu (shown at launch, game paused) and the pause
/// menu (shown via Escape during play) — same three actions either way, just
/// the primary button's title changes. A full-bounds translucent backdrop
/// that (unlike CrosshairView/DebugOverlayView) intentionally intercepts hit
/// testing while visible, so clicks/drags can't reach the game view underneath.
final class PauseMenuView: NSView, ControllerMenuNavigable {
    var onPlay: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let playButton: NSButton
    private let settingsButton: NSButton
    private let quitButton: NSButton
    private var buttons: [NSButton] { [playButton, settingsButton, quitButton] }
    private var focusedIndex = 0

    var playButtonTitle: String {
        get { playButton.title }
        set { playButton.title = newValue }
    }

    override init(frame frameRect: NSRect) {
        playButton = NSButton(title: "Play", target: nil, action: nil)
        settingsButton = NSButton(title: "Settings", target: nil, action: nil)
        quitButton = NSButton(title: "Quit", target: nil, action: nil)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Procedural Terrain")
        title.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        title.textColor = .white
        title.alignment = .center

        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.keyEquivalent = "\r"
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        quitButton.target = self
        quitButton.action = #selector(quitTapped)

        for button in buttons {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
        }

        let stack = NSStackView(views: [title] + buttons)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateFocusVisuals()
    }

    // MARK: ControllerMenuNavigable

    func resetFocus() {
        focusedIndex = 0
        updateFocusVisuals()
    }

    func moveFocus(by delta: Int) {
        let count = buttons.count
        focusedIndex = ((focusedIndex + delta) % count + count) % count
        updateFocusVisuals()
    }

    func adjustFocused(by delta: Int) {
        // No adjustable controls here — every item is a plain button.
    }

    func activateFocused() {
        buttons[focusedIndex].performClick(nil)
    }

    private func updateFocusVisuals() {
        for (index, button) in buttons.enumerated() {
            button.layer?.borderWidth = index == focusedIndex ? 3 : 0
            button.layer?.borderColor = NSColor.white.cgColor
        }
    }

    @objc private func playTapped() { onPlay?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func quitTapped() { onQuit?() }
}
