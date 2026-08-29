import Cocoa

/// Mouse sensitivity and render distance, the two knobs actually wired up on
/// the Renderer/Camera/ChunkManager side. Same full-bounds, hit-intercepting
/// backdrop pattern as PauseMenuView.
final class SettingsMenuView: NSView {
    var onBack: (() -> Void)?
    var onSensitivityChanged: ((Float) -> Void)?
    var onRenderDistanceChanged: ((Int) -> Void)?

    // Camera.lookSensitivity is radians-per-pixel and not a meaningful number
    // to show directly; the slider works in that raw range but the label
    // presents it as a friendlier 1...10 scale.
    private let minSensitivity: Float = 0.0008
    private let maxSensitivity: Float = 0.0060
    private let minRenderDistance = 3
    private let maxRenderDistance = 12

    private let sensitivitySlider = NSSlider()
    private let renderDistanceSlider = NSSlider()
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private let renderDistanceLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setInitialValues(sensitivity: Float, renderDistance: Int) {
        sensitivitySlider.floatValue = sensitivity
        renderDistanceSlider.integerValue = renderDistance
        updateLabels()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Settings")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.textColor = .white
        title.alignment = .center

        sensitivityLabel.textColor = .white
        sensitivityLabel.alignment = .center
        renderDistanceLabel.textColor = .white
        renderDistanceLabel.alignment = .center

        sensitivitySlider.minValue = Double(minSensitivity)
        sensitivitySlider.maxValue = Double(maxSensitivity)
        sensitivitySlider.target = self
        sensitivitySlider.action = #selector(sensitivityChanged)
        sensitivitySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true

        renderDistanceSlider.minValue = Double(minRenderDistance)
        renderDistanceSlider.maxValue = Double(maxRenderDistance)
        renderDistanceSlider.allowsTickMarkValuesOnly = true
        renderDistanceSlider.numberOfTickMarks = maxRenderDistance - minRenderDistance + 1
        renderDistanceSlider.target = self
        renderDistanceSlider.action = #selector(renderDistanceChanged)
        renderDistanceSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let backButton = NSButton(title: "Back", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        backButton.controlSize = .large
        backButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title,
            sensitivityLabel, sensitivitySlider,
            renderDistanceLabel, renderDistanceSlider,
            backButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(24, after: title)
        stack.setCustomSpacing(24, after: backButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateLabels()
    }

    private func updateLabels() {
        let t = (sensitivitySlider.floatValue - minSensitivity) / (maxSensitivity - minSensitivity)
        sensitivityLabel.stringValue = String(format: "Mouse sensitivity: %.0f / 10", t * 10)
        renderDistanceLabel.stringValue = "Render distance: \(renderDistanceSlider.integerValue) chunks"
    }

    @objc private func sensitivityChanged() {
        updateLabels()
        onSensitivityChanged?(sensitivitySlider.floatValue)
    }

    @objc private func renderDistanceChanged() {
        updateLabels()
        onRenderDistanceChanged?(renderDistanceSlider.integerValue)
    }

    @objc private func backTapped() { onBack?() }
}
