import Cocoa

/// Doubles as the main menu (shown at launch, game paused) and the pause
/// menu (shown via Escape during play) — same three actions either way, just
/// the primary button's title changes. A full-bounds translucent backdrop
/// that (unlike CrosshairView/DebugOverlayView) intentionally intercepts hit
/// testing while visible, so clicks/drags can't reach the game view underneath.
final class PauseMenuView: NSView {
    var onPlay: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let playButton: NSButton

    var playButtonTitle: String {
        get { playButton.title }
        set { playButton.title = newValue }
    }

    override init(frame frameRect: NSRect) {
        playButton = NSButton(title: "Play", target: nil, action: nil)
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

        let settingsButton = NSButton(title: "Settings", target: self, action: #selector(settingsTapped))
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.keyEquivalent = "\r"

        for button in [playButton, settingsButton, quitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }

        let stack = NSStackView(views: [title, playButton, settingsButton, quitButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func playTapped() { onPlay?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func quitTapped() { onQuit?() }
}
