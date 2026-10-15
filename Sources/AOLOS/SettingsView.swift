import AppKit

final class SettingsView: FlippedView {
    var onSave: ((AOLConfig) -> Void)?
    var onConnectGmail: (() -> Void)?
    var onDisconnectGmail: (() -> Void)?
    var onConnectSpotify: (() -> Void)?
    var onDisconnectSpotify: (() -> Void)?
    private var config: AOLConfig
    private let auth: GoogleAuth
    private let spotify: SpotifyAuth

    private let screenName = NSTextField()
    private let bankURL = NSTextField()
    private let touchID = NSButton(checkboxWithTitle: "Require Touch ID or Mac password to sign on", target: nil, action: nil)
    private let sounds = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
    private let checkMail = NSButton(checkboxWithTitle: "Check mail at sign on", target: nil, action: nil)
    private let clientID = NSTextField()
    private let clientSecret = NSSecureTextField()
    private let gmailStatus = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "Connect Gmail", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let spotifyID = NSTextField()
    private let spotifyStatus = NSTextField(labelWithString: "")
    private let spotifyConnect = NSButton(title: "Connect Spotify", target: nil, action: nil)
    private let spotifyDisconnect = NSButton(title: "Disconnect", target: nil, action: nil)

    init(config: AOLConfig, auth: GoogleAuth, spotify: SpotifyAuth) {
        self.config = config
        self.auth = auth
        self.spotify = spotify
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 440))

        screenName.stringValue = config.screenName
        bankURL.stringValue = config.service("finance")?.url ?? ""
        bankURL.placeholderString = "https://www.yourbank.com"
        touchID.state = config.requireTouchID ? .on : .off
        sounds.state = config.soundsEnabled ? .on : .off
        checkMail.state = config.openAtSignOn.contains("mail") ? .on : .off
        clientID.stringValue = auth.overrideClientID ?? ""
        clientID.placeholderString = GoogleClient.isConfigured ? "Built in. Leave blank." : "1234-abc.apps.googleusercontent.com"
        gmailStatus.font = Theme.ui(11)
        gmailStatus.textColor = Theme.mutedText
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)
        spotifyID.stringValue = spotify.overrideClientID ?? ""
        spotifyID.placeholderString = SpotifyClient.isConfigured ? "Built in. Leave blank." : "Spotify client ID"
        spotifyStatus.font = Theme.ui(11)
        spotifyStatus.textColor = Theme.mutedText
        spotifyConnect.target = self
        spotifyConnect.action = #selector(spotifyConnectTapped)
        spotifyDisconnect.target = self
        spotifyDisconnect.action = #selector(spotifyDisconnectTapped)
        let spotifyButtons = NSStackView(views: [spotifyConnect, spotifyDisconnect])
        spotifyButtons.orientation = .horizontal

        let soundsFolder = NSButton(title: "Open Sounds Folder", target: self, action: #selector(openSounds))
        let configFile = NSButton(title: "Edit config.json", target: self, action: #selector(openConfig))
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"

        let gmailButtons = NSStackView(views: [connectButton, disconnectButton])
        gmailButtons.orientation = .horizontal

        let form = NSGridView(views: [
            [label("Screen Name:"), screenName],
            [label("Bank URL:"), bankURL],
            [NSGridCell.emptyContentView, touchID],
            [NSGridCell.emptyContentView, sounds],
            [NSGridCell.emptyContentView, checkMail],
            [label("Gmail Client ID:"), clientID],
            [label("Client Secret:"), clientSecret],
            [NSGridCell.emptyContentView, gmailButtons],
            [NSGridCell.emptyContentView, gmailStatus],
            [label("Spotify App ID:"), spotifyID],
            [NSGridCell.emptyContentView, spotifyButtons],
            [NSGridCell.emptyContentView, spotifyStatus],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 320
        form.row(at: 5).topPadding = 14
        form.row(at: 9).topPadding = 14

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
        refreshGmailStatus()
        refreshSpotifyStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }

    func refreshGmailStatus() {
        if let email = auth.email, auth.isConnected {
            gmailStatus.stringValue = "Connected as \(email)"
        } else if auth.hasClient {
            gmailStatus.stringValue = "Not connected"
        } else {
            gmailStatus.stringValue = "This build has no Google OAuth client. See docs/gmail.md."
        }
        disconnectButton.isEnabled = auth.isConnected
        connectButton.title = auth.isConnected ? "Reconnect" : "Connect Gmail"
        if auth.overrideClientID != nil {
            clientSecret.placeholderString = auth.hasOverrideSecret ? "Saved in Keychain" : "Client secret"
        } else {
            clientSecret.placeholderString = GoogleClient.isConfigured ? "Built in. Leave blank." : "Client secret"
        }
    }

    func refreshSpotifyStatus() {
        if spotify.isConnected {
            spotifyStatus.stringValue = "Connected" + (spotify.userName.map { " as \($0)" } ?? "")
        } else if spotify.clientID != nil {
            spotifyStatus.stringValue = "Not connected"
        } else {
            spotifyStatus.stringValue = "This build has no Spotify app ID. See docs/spotify.md."
        }
        spotifyDisconnect.isEnabled = spotify.isConnected
        spotifyConnect.title = spotify.isConnected ? "Reconnect" : "Connect Spotify"
    }

    @objc private func spotifyConnectTapped() {
        if !spotifyID.stringValue.isEmpty || spotify.overrideClientID != nil { spotify.setClientID(spotifyID.stringValue) }
        refreshSpotifyStatus()
        onConnectSpotify?()
    }

    @objc private func spotifyDisconnectTapped() {
        onDisconnectSpotify?()
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.ui(12, bold: true)
        return l
    }

    @objc private func connectTapped() {
        if !clientID.stringValue.isEmpty || auth.overrideClientID != nil {
            auth.setClient(id: clientID.stringValue, secret: clientSecret.stringValue)
        }
        clientSecret.stringValue = ""
        refreshGmailStatus()
        onConnectGmail?()
    }

    @objc private func disconnectTapped() {
        onDisconnectGmail?()
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
        if checkMail.state == .on { config.openAtSignOn.insert("mail", at: 0) }
        if !clientID.stringValue.isEmpty || auth.overrideClientID != nil {
            auth.setClient(id: clientID.stringValue, secret: clientSecret.stringValue)
        }
        if !spotifyID.stringValue.isEmpty || spotify.overrideClientID != nil { spotify.setClientID(spotifyID.stringValue) }
        onSave?(config)
    }
}
