import Cocoa

/// The actual title screen — shown before any world is loaded (no Renderer/
/// MTKView exists yet at this point, see AppDelegate). Lists every saved
/// world (WorldStore), lets you create a new one, and play or delete the
/// selected one. PauseMenuView is the separate in-game pause overlay now
/// (Resume/Settings/"Quit to Title" — the latter tears the game down and
/// comes back here).
///
/// Row selection and the new-world name field are mouse/keyboard-only —
/// there's real text entry involved, so unlike every other menu here
/// there's no meaningful controller equivalent for that part. Controller
/// focus (see ControllerMenuNavigable) only cycles the actual buttons.
final class MainMenuView: NSView, ControllerMenuNavigable {
    var onPlayWorld: ((WorldMeta) -> Void)?
    var onQuit: (() -> Void)?

    private var worlds: [WorldMeta] = []
    private var selectedWorldID: UUID?

    private let worldsStack = NSStackView()
    private let nameField = NSTextField()
    private let seedField = NSTextField()
    private let createButton = NSButton(title: "Create World", target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No worlds yet — create one below")

    // Order the D-pad cycles through — row selection itself is mouse-only
    // (see the type doc comment).
    private enum FocusItem: Int, CaseIterable { case create, play, delete, quit }
    private var focusedItem: FocusItem = .create
    private var focusableViews: [FocusItem: NSButton] { [.create: createButton, .play: playButton, .delete: deleteButton, .quit: quitButton] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        buildUI()
        refreshWorlds()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Procedural Terrain")
        title.font = NSFont.systemFont(ofSize: 34, weight: .bold)
        title.textColor = .white
        title.alignment = .center

        let worldsPanel = NSView()
        worldsPanel.wantsLayer = true
        worldsPanel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        worldsPanel.layer?.cornerRadius = 10
        worldsPanel.translatesAutoresizingMaskIntoConstraints = false
        worldsPanel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        worldsPanel.heightAnchor.constraint(equalToConstant: 220).isActive = true

        worldsStack.orientation = .vertical
        worldsStack.alignment = .leading
        worldsStack.spacing = 6
        worldsStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        worldsStack.translatesAutoresizingMaskIntoConstraints = false
        worldsPanel.addSubview(worldsStack)
        NSLayoutConstraint.activate([
            worldsStack.topAnchor.constraint(equalTo: worldsPanel.topAnchor),
            worldsStack.leadingAnchor.constraint(equalTo: worldsPanel.leadingAnchor),
            worldsStack.trailingAnchor.constraint(equalTo: worldsPanel.trailingAnchor),
        ])

        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.6)

        nameField.placeholderString = "New world name"
        nameField.target = self
        nameField.action = #selector(createTapped) // Return key in the field also creates
        nameField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        seedField.placeholderString = "Seed (optional, random)"
        seedField.target = self
        seedField.action = #selector(createTapped) // Return key in the field also creates
        seedField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        createButton.target = self
        createButton.action = #selector(createTapped)
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.keyEquivalent = "\r"
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        quitButton.target = self
        quitButton.action = #selector(quitTapped)

        let createRow = NSStackView(views: [nameField, seedField, createButton])
        createRow.orientation = .horizontal
        createRow.spacing = 8

        let actionRow = NSStackView(views: [playButton, deleteButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12

        for button in [createButton, playButton, deleteButton, quitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.stylePillButton()
        }

        let stack = NSStackView(views: [title, worldsPanel, createRow, actionRow, quitButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(28, after: title)
        stack.setCustomSpacing(28, after: actionRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateFocusVisuals()
        updateActionButtonsEnabled()
    }

    private func refreshWorlds() {
        worlds = WorldStore.listWorlds()
        if let selectedWorldID, !worlds.contains(where: { $0.id == selectedWorldID }) {
            self.selectedWorldID = nil
        }

        for view in worldsStack.arrangedSubviews {
            worldsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if worlds.isEmpty {
            worldsStack.addArrangedSubview(emptyLabel)
        } else {
            for world in worlds {
                worldsStack.addArrangedSubview(makeRow(for: world))
            }
        }
        updateActionButtonsEnabled()
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func makeRow(for world: WorldMeta) -> NSButton {
        let subtitle = Self.dateFormatter.localizedString(for: world.lastPlayedAt, relativeTo: Date())
        let title = NSMutableAttributedString(string: world.name + "   ", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        title.append(NSAttributedString(string: "played \(subtitle)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]))

        let row = NSButton(title: "", target: self, action: #selector(rowTapped(_:)))
        row.attributedTitle = title
        row.alignment = .left
        row.isBordered = false // flat list row, not a real action button — selection is our own layer tint/border below
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        let isSelected = world.id == selectedWorldID
        row.layer?.backgroundColor = (isSelected ? NSColor.white.withAlphaComponent(0.15) : .clear).cgColor
        row.layer?.borderWidth = isSelected ? 2 : 0
        row.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        row.widthAnchor.constraint(equalToConstant: 392).isActive = true
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        row.identifier = NSUserInterfaceItemIdentifier(world.id.uuidString)
        return row
    }

    private func updateActionButtonsEnabled() {
        let hasSelection = selectedWorldID != nil
        playButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    @objc private func rowTapped(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue, let id = UUID(uuidString: identifier) else { return }
        selectedWorldID = id
        refreshWorlds()
    }

    @objc private func createTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let world = WorldStore.createWorld(name: name, seed: Self.parseSeed(seedField.stringValue))
        nameField.stringValue = ""
        seedField.stringValue = ""
        selectedWorldID = world.id
        refreshWorlds()
    }

    /// Blank means "no preference" (WorldStore picks a fresh random seed).
    /// A plain number is used as-is; any other text is hashed into one
    /// (FNV-1a, stable across launches) so a word or phrase works as a seed
    /// too, the same "type anything" convention Minecraft's own seed field
    /// uses, rather than requiring players to type a raw 64-bit number.
    private static func parseSeed(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = UInt64(trimmed) { return value }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    @objc private func playTapped() {
        guard let selectedWorldID, let world = worlds.first(where: { $0.id == selectedWorldID }) else { return }
        onPlayWorld?(world)
    }

    @objc private func deleteTapped() {
        guard let selectedWorldID else { return }
        WorldStore.deleteWorld(selectedWorldID)
        self.selectedWorldID = nil
        refreshWorlds()
    }

    @objc private func quitTapped() { onQuit?() }

    /// Called by AppDelegate whenever this becomes visible again (including
    /// after "Quit to Title") so a world just played resurfaces with its
    /// updated lastPlayedAt instead of a stale ordering.
    func viewWillAppear() {
        refreshWorlds()
    }

    // MARK: ControllerMenuNavigable

    func resetFocus() {
        focusedItem = .create
        updateFocusVisuals()
    }

    func moveFocus(by delta: Int) {
        let all = FocusItem.allCases
        let currentIndex = all.firstIndex(of: focusedItem) ?? 0
        focusedItem = all[((currentIndex + delta) % all.count + all.count) % all.count]
        updateFocusVisuals()
    }

    func adjustFocused(by delta: Int) {
        // No adjustable controls here — every focusable item is a plain button.
    }

    func activateFocused() {
        focusableViews[focusedItem]?.performClick(nil)
    }

    private func updateFocusVisuals() {
        for (item, view) in focusableViews {
            view.layer?.borderWidth = item == focusedItem ? 3 : 0
            view.layer?.borderColor = NSColor.white.cgColor
        }
    }
}
