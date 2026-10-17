import AppKit

final class SettingsView: FlippedView {
    var onSave: ((AOLConfig) -> Void)?
    /// Nil adds an account. An address signs that account in again.
    var onConnectGmail: ((String?) -> Void)?
    var onRemoveGmail: ((String) -> Void)?
    var onMakePrimaryGmail: ((String) -> Void)?
    var onConnectSpotify: (() -> Void)?
    var onDisconnectSpotify: (() -> Void)?
    var onConnectSlack: ((String?, String?) -> Void)?
    var onDisconnectSlack: (() -> Void)?
    var onMakeDefaultBrowser: (() -> Void)?
    weak var slack: SlackClient? { didSet { refreshSlackStatus() } }
    private var config: AOLConfig
    private let mail: MailCenter
    private let spotify: SpotifyAuth

    private let screenName = NSTextField()
    private let bankURL = NSTextField()
    private let touchID = NSButton(checkboxWithTitle: "Require Touch ID or Mac password to sign on", target: nil, action: nil)
    private let sounds = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
    private let checkMail = NSButton(checkboxWithTitle: "Check mail at sign on", target: nil, action: nil)
    private let darkWeb = NSButton(checkboxWithTitle: "Dark mode for web pages", target: nil, action: nil)
    private let darkTheme = NSButton(checkboxWithTitle: "Dark AOL-OS theme (experimental)", target: nil, action: nil)
    private let clientID = NSTextField()
    private let clientSecret = NSSecureTextField()
    private let gmailStatus = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Add Account", target: nil, action: nil)
    private let manageButton = NSButton(title: "Manage Accounts", target: nil, action: nil)
    private let spotifyID = NSTextField()
    private let spotifyStatus = NSTextField(labelWithString: "")
    private let spotifyConnect = NSButton(title: "Connect Spotify", target: nil, action: nil)
    private let spotifyDisconnect = NSButton(title: "Disconnect", target: nil, action: nil)
    private let slackUserToken = NSSecureTextField()
    private let slackAppToken = NSSecureTextField()
    private let slackStatus = NSTextField(wrappingLabelWithString: "")
    private let slackConnect = NSButton(title: "Connect Slack", target: nil, action: nil)
    private let slackDisconnect = NSButton(title: "Disconnect", target: nil, action: nil)
    private let browserButton = NSButton(title: "Make Default Browser", target: nil, action: nil)
    private let browserStatus = NSTextField(wrappingLabelWithString: "")

    init(config: AOLConfig, mail: MailCenter, spotify: SpotifyAuth) {
        self.config = config
        self.mail = mail
        self.spotify = spotify
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 440))

        screenName.stringValue = config.screenName
        bankURL.stringValue = config.service("finance")?.url ?? ""
        bankURL.placeholderString = "https://www.yourbank.com"
        touchID.state = config.requireTouchID ? .on : .off
        sounds.state = config.soundsEnabled ? .on : .off
        checkMail.state = config.openAtSignOn.contains("mail") ? .on : .off
        darkWeb.state = config.darkWebPages ? .on : .off
        darkTheme.state = config.darkTheme ? .on : .off
        clientID.stringValue = GoogleAccounts.overrideClientID ?? ""
        clientID.placeholderString = GoogleClient.isConfigured ? "Built in. Leave blank." : "1234-abc.apps.googleusercontent.com"
        gmailStatus.font = Theme.ui(11)
        gmailStatus.textColor = Theme.mutedText
        gmailStatus.preferredMaxLayoutWidth = 320
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        manageButton.target = self
        manageButton.action = #selector(manageTapped)
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
        slackStatus.font = Theme.ui(11)
        slackStatus.textColor = Theme.mutedText
        slackStatus.preferredMaxLayoutWidth = 320
        slackConnect.target = self
        slackConnect.action = #selector(slackConnectTapped)
        slackDisconnect.target = self
        slackDisconnect.action = #selector(slackDisconnectTapped)
        let slackButtons = NSStackView(views: [slackConnect, slackDisconnect])
        slackButtons.orientation = .horizontal

        browserStatus.font = Theme.ui(11)
        browserStatus.textColor = Theme.mutedText
        browserStatus.preferredMaxLayoutWidth = 320
        browserButton.target = self
        browserButton.action = #selector(browserTapped)

        let soundsFolder = NSButton(title: "Open Sounds Folder", target: self, action: #selector(openSounds))
        let configFile = NSButton(title: "Edit config.json", target: self, action: #selector(openConfig))
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"

        let gmailButtons = NSStackView(views: [connectButton, manageButton])
        gmailButtons.orientation = .horizontal

        let form = NSGridView(views: [
            [label("Screen Name:"), screenName],
            [label("Bank URL:"), bankURL],
            [NSGridCell.emptyContentView, touchID],
            [NSGridCell.emptyContentView, sounds],
            [NSGridCell.emptyContentView, checkMail],
            [NSGridCell.emptyContentView, darkWeb],
            [NSGridCell.emptyContentView, darkTheme],
            [label("Gmail Client ID:"), clientID],
            [label("Client Secret:"), clientSecret],
            [NSGridCell.emptyContentView, gmailButtons],
            [NSGridCell.emptyContentView, gmailStatus],
            [label("Spotify App ID:"), spotifyID],
            [NSGridCell.emptyContentView, spotifyButtons],
            [NSGridCell.emptyContentView, spotifyStatus],
            [label("Slack User Token:"), slackUserToken],
            [label("Slack App Token:"), slackAppToken],
            [NSGridCell.emptyContentView, slackButtons],
            [NSGridCell.emptyContentView, slackStatus],
            [label("Web Browser:"), browserButton],
            [NSGridCell.emptyContentView, browserStatus],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 320
        form.row(at: 7).topPadding = 14
        form.row(at: 9).topPadding = 14
        form.row(at: 12).topPadding = 14
        form.row(at: 16).topPadding = 14

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
        refreshSlackStatus()
        refreshBrowserStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }

    func refreshGmailStatus() {
        let accounts = mail.accounts
        if !accounts.isEmpty {
            gmailStatus.stringValue = accounts.enumerated().map { i, s in
                var line = s.email
                if !s.auth.isConnected { line += " (signed out, reconnect)" } else if i == 0, accounts.count > 1 { line += " (primary)" }
                return line
            }.joined(separator: "\n")
        } else if mail.hasClient {
            gmailStatus.stringValue = "Not connected"
        } else {
            gmailStatus.stringValue = "This build has no Google OAuth client. See docs/gmail.md."
        }
        manageButton.isEnabled = !accounts.isEmpty
        connectButton.title = accounts.isEmpty ? "Connect Gmail" : "Add Account"
        if GoogleAccounts.overrideClientID != nil {
            clientSecret.placeholderString = GoogleAccounts.hasOverrideSecret ? "Saved in Keychain" : "Client secret"
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

    func refreshSlackStatus() {
        slackUserToken.placeholderString = SlackClient.userToken == nil ? "xoxp-..." : "Saved in Keychain"
        slackAppToken.placeholderString = SlackClient.appToken == nil ? "xapp-... for live messages" : "Saved in Keychain"
        let state = slack?.state ?? .off
        switch state {
        case .ready:
            let team = slack?.team?.name ?? "Slack"
            let who = slack?.me?.name ?? ""
            var text = "Connected to \(team)" + (who.isEmpty ? "" : " as \(who)")
            if SlackClient.appToken == nil {
                text += ". Add an app token for live messages."
            } else if slack?.isLive == false {
                text += ". Live messages are reconnecting."
            }
            slackStatus.stringValue = text
        case .connecting:
            slackStatus.stringValue = "Connecting to Slack..."
        case .failed(let message):
            slackStatus.stringValue = message
        case .off:
            slackStatus.stringValue = SlackClient.isConfigured ? "Not connected" : "Paste the tokens from your Slack app. See docs/slack.md."
        }
        slackDisconnect.isEnabled = SlackClient.isConfigured
        slackConnect.title = state == .ready ? "Reconnect" : "Connect Slack"
    }

    func refreshBrowserStatus() {
        if DefaultBrowser.isDefault {
            browserStatus.stringValue = "AOL-OS opens the web links you click in other apps."
        } else if DefaultBrowser.isBundled {
            browserStatus.stringValue = "Open web links from other apps in AOL-OS. macOS asks you to confirm."
        } else {
            browserStatus.stringValue = "Run make install, then open AOL-OS from Applications to use it as your browser."
        }
        browserButton.isEnabled = DefaultBrowser.isBundled && !DefaultBrowser.isDefault
    }

    @objc private func browserTapped() {
        onMakeDefaultBrowser?()
    }

    @objc private func slackConnectTapped() {
        let user = slackUserToken.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = slackAppToken.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        slackUserToken.stringValue = ""
        slackAppToken.stringValue = ""
        onConnectSlack?(user.isEmpty ? nil : user, app.isEmpty ? nil : app)
    }

    @objc private func slackDisconnectTapped() {
        onDisconnectSlack?()
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

    private func saveGoogleClient() {
        if !clientID.stringValue.isEmpty || GoogleAccounts.overrideClientID != nil {
            GoogleAccounts.setClient(id: clientID.stringValue, secret: clientSecret.stringValue)
        }
        clientSecret.stringValue = ""
    }

    @objc private func connectTapped() {
        saveGoogleClient()
        refreshGmailStatus()
        onConnectGmail?(nil)
    }

    /// One section per account: Reconnect, Make Primary, Remove.
    @objc private func manageTapped() {
        let menu = NSMenu()
        for (i, s) in mail.accounts.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            let title = NSMenuItem(title: s.email, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let email = s.email
            menu.addItem(ActionItem("Reconnect") { [weak self] in
                self?.saveGoogleClient()
                self?.onConnectGmail?(email)
            })
            let primary = ActionItem("Make Primary") { [weak self] in self?.onMakePrimaryGmail?(email) }
            primary.isEnabled = i > 0
            menu.addItem(primary)
            menu.addItem(ActionItem("Remove...") { [weak self] in self?.onRemoveGmail?(email) })
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: manageButton.bounds.height + 4), in: manageButton)
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
        config.darkWebPages = darkWeb.state == .on
        config.darkTheme = darkTheme.state == .on
        config.openAtSignOn.removeAll { $0 == "mail" }
        if checkMail.state == .on { config.openAtSignOn.insert("mail", at: 0) }
        if !clientID.stringValue.isEmpty || GoogleAccounts.overrideClientID != nil {
            GoogleAccounts.setClient(id: clientID.stringValue, secret: clientSecret.stringValue)
        }
        if !spotifyID.stringValue.isEmpty || spotify.overrideClientID != nil { spotify.setClientID(spotifyID.stringValue) }
        onSave?(config)
    }
}
