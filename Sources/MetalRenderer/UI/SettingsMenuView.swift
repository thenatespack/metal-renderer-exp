import Cocoa

/// Game mode, mouse sensitivity, render distance, resolution scale, FPS cap,
/// and post effect — the knobs actually wired up on the
/// Renderer/Camera/ChunkManager/RendererView side. Same full-bounds,
/// hit-intercepting backdrop pattern as PauseMenuView.
final class SettingsMenuView: NSView, ControllerMenuNavigable {
    var onBack: (() -> Void)?
    var onSensitivityChanged: ((Float) -> Void)?
    var onRenderDistanceChanged: ((Int) -> Void)?
    var onGameModeChanged: ((GameMode) -> Void)?
    var onResolutionScaleChanged: ((Float) -> Void)?
    var onFPSChanged: ((Int) -> Void)?
    var onPostEffectChanged: ((PostEffect) -> Void)?

    // Camera.lookSensitivity is radians-per-pixel and not a meaningful number
    // to show directly; the slider works in that raw range but the label
    // presents it as a friendlier 1...10 scale.
    private let minSensitivity: Float = 0.0008
    private let maxSensitivity: Float = 0.0060
    private let sensitivityStep: Float = 0.0005 // one D-pad nudge ≈ 1/10 of the range
    private let minRenderDistance = 3
    private let maxRenderDistance = 48

    // Resolution scale: fraction of the drawable's native pixels the scene
    // is actually rendered at (see Renderer's offscreen texture + post
    // pass) — three discrete steps, like renderDistanceSlider's tick marks.
    private let resolutionSteps: [Float] = [0.5, 0.75, 1.0]
    // FPS cap options; 0 is the "Uncapped" sentinel (see RendererView/AppDelegate).
    private let fpsSteps = [30, 60, 120, 0]
    private let fpsLabels = ["30", "60", "120", "Uncapped"]

    private let gameModeControl = NSSegmentedControl(labels: ["Creative", "Survival"], trackingMode: .selectOne, target: nil, action: nil)
    private let sensitivitySlider = NSSlider()
    private let renderDistanceSlider = NSSlider()
    private let resolutionSlider = NSSlider()
    private let fpsControl = NSSegmentedControl(labels: ["30", "60", "120", "Uncapped"], trackingMode: .selectOne, target: nil, action: nil)
    private let postEffectControl = NSPopUpButton()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private let renderDistanceLabel = NSTextField(labelWithString: "")
    private let resolutionLabel = NSTextField(labelWithString: "")
    private let gameModeLabel = NSTextField(labelWithString: "Game mode")
    private let fpsLabel = NSTextField(labelWithString: "FPS cap")
    private let postEffectLabel = NSTextField(labelWithString: "Post effect")

    // Order the D-pad cycles through.
    private enum FocusItem: Int, CaseIterable { case gameMode, sensitivity, renderDistance, resolution, fps, postEffect, back }
    private var focusedItem: FocusItem = .gameMode
    private var focusableViews: [FocusItem: NSView] {
        [.gameMode: gameModeControl, .sensitivity: sensitivitySlider, .renderDistance: renderDistanceSlider,
         .resolution: resolutionSlider, .fps: fpsControl, .postEffect: postEffectControl, .back: backButton]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setInitialValues(sensitivity: Float, renderDistance: Int, gameMode: GameMode, resolutionScale: Float, fps: Int, postEffect: PostEffect) {
        sensitivitySlider.floatValue = sensitivity
        renderDistanceSlider.integerValue = renderDistance
        gameModeControl.selectedSegment = gameMode == .creative ? 0 : 1
        resolutionSlider.integerValue = resolutionSteps.firstIndex(of: resolutionScale) ?? resolutionSteps.count - 1
        fpsControl.selectedSegment = fpsSteps.firstIndex(of: fps) ?? 1
        postEffectControl.selectItem(at: postEffect.rawValue)
        updateLabels()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Settings")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.textColor = .white
        title.alignment = .center

        gameModeLabel.textColor = .white
        gameModeLabel.alignment = .center
        gameModeControl.target = self
        gameModeControl.action = #selector(gameModeChanged)
        gameModeControl.widthAnchor.constraint(equalToConstant: 240).isActive = true

        sensitivityLabel.textColor = .white
        sensitivityLabel.alignment = .center
        renderDistanceLabel.textColor = .white
        renderDistanceLabel.alignment = .center
        resolutionLabel.textColor = .white
        resolutionLabel.alignment = .center
        fpsLabel.textColor = .white
        fpsLabel.alignment = .center
        postEffectLabel.textColor = .white
        postEffectLabel.alignment = .center

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

        resolutionSlider.minValue = 0
        resolutionSlider.maxValue = Double(resolutionSteps.count - 1)
        resolutionSlider.allowsTickMarkValuesOnly = true
        resolutionSlider.numberOfTickMarks = resolutionSteps.count
        resolutionSlider.target = self
        resolutionSlider.action = #selector(resolutionChanged)
        resolutionSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true

        fpsControl.target = self
        fpsControl.action = #selector(fpsChanged)
        fpsControl.widthAnchor.constraint(equalToConstant: 240).isActive = true

        postEffectControl.addItems(withTitles: PostEffect.allCases.map { $0.label })
        postEffectControl.target = self
        postEffectControl.action = #selector(postEffectChanged)
        postEffectControl.widthAnchor.constraint(equalToConstant: 240).isActive = true

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.bezelStyle = .rounded
        backButton.controlSize = .large
        backButton.keyEquivalent = "\r"

        for view in focusableViews.values {
            view.wantsLayer = true
            view.layer?.cornerRadius = 6
        }
        // Real NSButton needs its own solid fill on top of the above — see
        // stylePillButton's doc comment for why wantsLayer alone leaves it
        // see-through. The other controls (segmented/slider/popup) don't
        // share that bug, so they're left with just the generic loop above.
        backButton.stylePillButton()

        let stack = NSStackView(views: [
            title,
            gameModeLabel, gameModeControl,
            sensitivityLabel, sensitivitySlider,
            renderDistanceLabel, renderDistanceSlider,
            resolutionLabel, resolutionSlider,
            fpsLabel, fpsControl,
            postEffectLabel, postEffectControl,
            backButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(24, after: title)
        stack.setCustomSpacing(20, after: gameModeControl)
        stack.setCustomSpacing(24, after: backButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateLabels()
        updateFocusVisuals()
    }

    private func updateLabels() {
        let t = (sensitivitySlider.floatValue - minSensitivity) / (maxSensitivity - minSensitivity)
        sensitivityLabel.stringValue = String(format: "Mouse sensitivity: %.0f / 10", t * 10)
        renderDistanceLabel.stringValue = "Render distance: \(renderDistanceSlider.integerValue) chunks"
        let scale = resolutionSteps[resolutionSlider.integerValue]
        resolutionLabel.stringValue = "Resolution scale: \(Int(scale * 100))%"
    }

    // MARK: ControllerMenuNavigable

    func resetFocus() {
        focusedItem = .gameMode
        updateFocusVisuals()
    }

    func moveFocus(by delta: Int) {
        let all = FocusItem.allCases
        let currentIndex = all.firstIndex(of: focusedItem) ?? 0
        focusedItem = all[((currentIndex + delta) % all.count + all.count) % all.count]
        updateFocusVisuals()
    }

    func adjustFocused(by delta: Int) {
        switch focusedItem {
        case .gameMode:
            let newSegment = max(0, min(1, gameModeControl.selectedSegment + delta))
            guard newSegment != gameModeControl.selectedSegment else { return }
            gameModeControl.selectedSegment = newSegment
            gameModeChanged()
        case .sensitivity:
            let newValue = max(minSensitivity, min(maxSensitivity, sensitivitySlider.floatValue + Float(delta) * sensitivityStep))
            sensitivitySlider.floatValue = newValue
            sensitivityChanged()
        case .renderDistance:
            let newValue = max(minRenderDistance, min(maxRenderDistance, renderDistanceSlider.integerValue + delta))
            renderDistanceSlider.integerValue = newValue
            renderDistanceChanged()
        case .resolution:
            let newValue = max(0, min(resolutionSteps.count - 1, resolutionSlider.integerValue + delta))
            guard newValue != resolutionSlider.integerValue else { return }
            resolutionSlider.integerValue = newValue
            resolutionChanged()
        case .fps:
            let newSegment = max(0, min(fpsSteps.count - 1, fpsControl.selectedSegment + delta))
            guard newSegment != fpsControl.selectedSegment else { return }
            fpsControl.selectedSegment = newSegment
            fpsChanged()
        case .postEffect:
            let newIndex = max(0, min(PostEffect.allCases.count - 1, postEffectControl.indexOfSelectedItem + delta))
            guard newIndex != postEffectControl.indexOfSelectedItem else { return }
            postEffectControl.selectItem(at: newIndex)
            postEffectChanged()
        case .back:
            break
        }
    }

    func activateFocused() {
        if focusedItem == .back {
            backButton.performClick(nil)
        }
        // Sliders/segmented control are already live via adjustFocused — Cross doesn't need to do anything extra for them.
    }

    private func updateFocusVisuals() {
        for (item, view) in focusableViews {
            view.layer?.borderWidth = item == focusedItem ? 3 : 0
            view.layer?.borderColor = NSColor.white.cgColor
        }
    }

    @objc private func gameModeChanged() {
        let mode: GameMode = gameModeControl.selectedSegment == 0 ? .creative : .survival
        onGameModeChanged?(mode)
    }

    @objc private func sensitivityChanged() {
        updateLabels()
        onSensitivityChanged?(sensitivitySlider.floatValue)
    }

    @objc private func renderDistanceChanged() {
        updateLabels()
        onRenderDistanceChanged?(renderDistanceSlider.integerValue)
    }

    @objc private func resolutionChanged() {
        updateLabels()
        onResolutionScaleChanged?(resolutionSteps[resolutionSlider.integerValue])
    }

    @objc private func fpsChanged() {
        onFPSChanged?(fpsSteps[fpsControl.selectedSegment])
    }

    @objc private func postEffectChanged() {
        guard let effect = PostEffect(rawValue: postEffectControl.indexOfSelectedItem) else { return }
        onPostEffectChanged?(effect)
    }

    @objc private func backTapped() { onBack?() }
}
