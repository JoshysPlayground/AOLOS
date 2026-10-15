import AppKit

final class SettingsView: FlippedView {
    var onSave: ((AOLConfig) -> Void)?
    private var config: AOLConfig

    private let screenName = NSTextField()
    private let bankURL = NSTextField()
    private let touchID = NSButton(checkboxWithTitle: "Require Touch ID or Mac password to sign on", target: nil, action: nil)
    private let sounds = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
    private let openMailAtSignOn = NSButton(checkboxWithTitle: "Check mail at sign on", target: nil, action: nil)

    init(config: AOLConfig) {
        self.config = config
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 360))

        screenName.stringValue = config.screenName
        bankURL.stringValue = config.service("finance")?.url ?? ""
        bankURL.placeholderString = "https://www.yourbank.com"
        touchID.state = config.requireTouchID ? .on : .off
        sounds.state = config.soundsEnabled ? .on : .off
        openMailAtSignOn.state = config.openAtSignOn.contains("mail") ? .on : .off

        let soundsFolder = NSButton(title: "Open Sounds Folder", target: self, action: #selector(openSounds))
        let configFile = NSButton(title: "Edit config.json", target: self, action: #selector(openConfig))
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"

        let form = NSGridView(views: [
            [label("Screen Name:"), screenName],
            [label("Bank URL:"), bankURL],
            [NSGridCell.emptyContentView, touchID],
            [NSGridCell.emptyContentView, sounds],
            [NSGridCell.emptyContentView, openMailAtSignOn],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 300

        let buttons = NSStackView(views: [soundsFolder, configFile, NSView(), save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [form, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: form.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.ui(12, bold: true)
        return l
    }

    @objc private func openSounds() {
        SoundManager.writeSoundsReadme()
        NSWorkspace.shared.open(AppPaths.sounds)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(AppPaths.config)
    }

    @objc private func saveTapped() {
        let name = screenName.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { config.screenName = name }
        if var finance = config.service("finance") {
            finance.url = bankURL.stringValue.trimmingCharacters(in: .whitespaces)
            config.update(finance)
        }
        config.requireTouchID = touchID.state == .on
        config.soundsEnabled = sounds.state == .on
        config.openAtSignOn.removeAll { $0 == "mail" }
        if openMailAtSignOn.state == .on { config.openAtSignOn.insert("mail", at: 0) }
        onSave?(config)
    }
}
