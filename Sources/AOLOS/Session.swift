import AppKit
import LocalAuthentication
import WebKit

/// Owns the signed-on state, config and every open window. All UI actions route through here.
@MainActor
final class Session {
    private(set) var config: AOLConfig
    let shell: ShellView
    private(set) var signedOn = false

    private var signOnWindow: MDIWindow?
    private var signOnView: SignOnView?
    private var welcomeWindow: MDIWindow?
    var welcomePane: WelcomePane?
    private var settingsWindow: MDIWindow?
    private var serviceWindows: [String: MDIWindow] = [:]
    private var savePromptHosts: Set<String> = []
    let mail = MailService()
    var mailboxWindow: MDIWindow?
    var mailboxView: MailboxView?
    var settingsView: SettingsView?
    let spotify = SpotifyService()
    var radioWindow: MDIWindow?
    var radioView: RadioView?

    var desktop: DesktopView { shell.desktop }
    var activeWebPane: WebPane? { desktop.activeWindow?.content as? WebPane }

    init(shell: ShellView) {
        self.shell = shell
        self.config = ConfigStore.load()
        SoundManager.shared.enabled = config.soundsEnabled
        SoundManager.writeSoundsReadme()
        buildChrome()
        setUpMail()
        desktop.onChange = { [weak self] in self?.refreshNav() }
    }

    func start() {
        shell.layoutSubtreeIfNeeded()
        showSignOn()
    }


    private func showSignOn() {
        signedOn = false
        shell.setSignedOn(false)
        shell.statusBar.screenName = ""
        shell.statusBar.status = "Ready to sign on"

        let view = SignOnView(screenName: config.screenName, usesTouchID: config.requireTouchID)
        view.onSignOn = { [weak self] name in self?.signOn(as: name) }
        let window = MDIWindow(title: "Sign On", icon: Icons.symbol("person.crop.circle.fill", colors: [.white]), content: view)
        window.closable = false
        window.minimizable = false
        window.resizable = false
        window.focusView = view
        desktop.add(window, size: NSSize(width: 428, height: 414), centered: true)
        signOnWindow = window
        signOnView = view
    }

    private func signOn(as name: String) {
        config.screenName = name
        ConfigStore.save(config)
        signOnView?.setBusy(true)
        authenticate { [weak self] ok, message in
            guard let self else { return }
            guard ok else {
                self.signOnView?.showError(message ?? "Sign on was cancelled.")
                return
            }
            self.signOnView?.runConnectingSequence { [weak self] in self?.completeSignOn() }
        }
    }

    private func authenticate(_ completion: @escaping @MainActor (Bool, String?) -> Void) {
        guard config.requireTouchID else { completion(true, nil); return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true, nil)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sign on to AOL-OS") { ok, error in
            DispatchQueue.main.async {
                completion(ok, error?.localizedDescription)
            }
        }
    }

    private func completeSignOn() {
        if let w = signOnWindow { desktop.close(w) }
        signOnWindow = nil
        signOnView = nil
        signedOn = true
        shell.setSignedOn(true)
        shell.statusBar.screenName = config.screenName
        SoundManager.shared.play(.welcome)
        if config.openAtSignOn.contains("mail") { mail.start() }
        for id in config.openAtSignOn where id != "mail" && id != "write" { openService(id, minimized: true) }
        openWelcome()
    }

    func signOff() {
        guard signedOn else { return }
        SoundManager.shared.play(.goodbye)
        mail.stop()
        spotify.stopPolling()
        desktop.closeAll(includingPinned: true)
        serviceWindows.removeAll()
        mailboxWindow = nil
        mailboxView = nil
        settingsView = nil
        welcomeWindow = nil
        welcomePane = nil
        settingsWindow = nil
        showSignOn()
    }

    func quit() {
        guard signedOn else { NSApp.terminate(nil); return }
        SoundManager.shared.play(.goodbye)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
    }


    func openWelcome() {
        guard signedOn else { return }
        if let w = welcomeWindow, w.superview != nil { desktop.activate(w); return }
        let pane = WelcomePane(session: self, screenName: config.screenName)
        let window = MDIWindow(title: "Welcome", icon: Icons.symbol("house.fill", colors: [.white]), content: pane)
        window.focusView = pane.webView
        window.onClose = { [weak self] in self?.welcomeWindow = nil; self?.welcomePane = nil }
        welcomeWindow = window
        welcomePane = pane
        desktop.add(window)
        updateWelcomeMail()
    }

    func openSettings() {
        guard signedOn else { return }
        if let w = settingsWindow, w.superview != nil { desktop.activate(w); return }
        let view = SettingsView(config: config, auth: mail.auth, spotify: spotify.auth)
        view.onConnectGmail = { [weak self] in self?.connectGmail() }
        view.onDisconnectGmail = { [weak self] in self?.disconnectGmail() }
        view.onConnectSpotify = { [weak self] in self?.connectSpotify() }
        view.onDisconnectSpotify = { [weak self] in self?.disconnectSpotify() }
        settingsView = view
        let window = MDIWindow(title: "Settings", icon: Icons.symbol("gearshape.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 480, height: 330)
        view.onSave = { [weak self, weak window] newConfig in
            self?.apply(newConfig)
            if let window { self?.desktop.close(window) }
        }
        window.onClose = { [weak self] in self?.settingsWindow = nil; self?.settingsView = nil }
        settingsWindow = window
        desktop.add(window, size: NSSize(width: 580, height: 600), centered: true)
    }

    func updateConfig(_ change: (inout AOLConfig) -> Void) {
        change(&config)
        ConfigStore.save(config)
    }

    private func apply(_ newConfig: AOLConfig) {
        config = newConfig
        ConfigStore.save(config)
        SoundManager.shared.enabled = config.soundsEnabled
        shell.statusBar.screenName = config.screenName
    }

    /// `mail` and `write` open the native mailbox unless `web` asks for the Gmail web app.
    func openService(_ id: String, minimized: Bool = false, web: Bool = false) {
        guard signedOn else { NSSound.beep(); return }
        switch id {
        case "welcome": openWelcome(); return
        case "settings": openSettings(); return
        case "mail" where !web: openMailbox(minimized: minimized); return
        case "write" where !web: openCompose(); return
        case "radio": openRadio(); return
        case "spotify" where !web: openRadio(); return
        default: break
        }
        guard let service = config.service(id) else { go(id); return }
        if let w = serviceWindows[id], w.superview != nil {
            if !minimized { desktop.activate(w) }
            return
        }
        guard let url = URL(string: service.url), url.scheme != nil else {
            promptForURL(service)
            return
        }
        let pane = WebPane(url: url, service: service, session: self)
        let window = MDIWindow(title: service.title, icon: Icons.symbol(service.icon, colors: [.white]), content: pane)
        pane.host = window
        window.focusView = pane.webView
        window.onClose = { [weak self] in self?.serviceWindows[id] = nil }
        serviceWindows[id] = window
        desktop.add(window, minimized: minimized)
    }

    private func promptForURL(_ service: ServiceDef) {
        guard let value = Prompt.text(title: "Set up \(service.title)",
                                      message: "Enter the web address AOL-OS should open for \(service.title).",
                                      placeholder: "https://", confirm: "Save"),
              let url = Self.webURL(from: value) else { return }
        var updated = service
        updated.url = url.absoluteString
        config.update(updated)
        ConfigStore.save(config)
        openService(service.id)
    }

    @discardableResult
    func openBrowser(_ url: URL) -> WebPane {
        let pane = WebPane(url: url, service: nil, session: self)
        let window = MDIWindow(title: url.host ?? "Browser", icon: Icons.symbol("globe", colors: [.white]), content: pane)
        pane.host = window
        window.focusView = pane.webView
        desktop.add(window)
        return pane
    }

    func openPopup(configuration: WKWebViewConfiguration, from opener: WebPane, features: WKWindowFeatures) -> WKWebView {
        let pane = WebPane(url: nil, service: opener.service, session: self, configuration: configuration)
        let title = opener.service.map { "\($0.title) Popup" } ?? "Browser"
        let window = MDIWindow(title: title, icon: Icons.symbol("macwindow", colors: [.white]), content: pane)
        pane.host = window
        window.focusView = pane.webView
        let width = CGFloat(features.width?.doubleValue ?? 560)
        let height = CGFloat(features.height?.doubleValue ?? 680) + MDIWindow.titleHeight + MDIWindow.border * 2
        desktop.add(window, size: NSSize(width: width, height: height), centered: true)
        return pane.webView
    }

    func compose(mailto: URL) {
        guard mail.auth.isConnected else {
            var c = URLComponents(string: "https://mail.google.com/mail/")!
            c.queryItems = [URLQueryItem(name: "extsrc", value: "mailto"), URLQueryItem(name: "url", value: mailto.absoluteString)]
            if let url = c.url { openBrowser(url) }
            return
        }
        let parts = URLComponents(url: mailto, resolvingAgainstBaseURL: false)
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }) { a, _ in a }
        openCompose(to: parts?.path.removingPercentEncoding ?? "", cc: query["cc"] ?? "",
                    subject: query["subject"] ?? "", body: query["body"] ?? "")
    }


    func promptKeyword() {
        guard signedOn else { return }
        if let text = Prompt.text(title: "Keyword", message: "Type a Keyword or Web Address.",
                                  placeholder: "mail, discord, spotify, or a web address", confirm: "Go") {
            go(text)
        }
    }

    func go(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = text.lowercased()
        if key == "gmail" || key == "gmail web" {
            openService("mail", web: true)
        } else if key == "radio" || key == "aol radio" {
            openRadio()
        } else if key == "spotify web" {
            openService("spotify", web: true)
        } else if let target = config.keywords[key] {
            openService(target)
        } else if config.service(key) != nil || key == "welcome" || key == "settings" {
            openService(key)
        } else if let url = Self.webURL(from: text) {
            if let pane = activeWebPane, pane.service == nil {
                pane.webView.load(URLRequest(url: url))
            } else {
                openBrowser(url)
            }
        } else {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = c.url { openBrowser(url) }
        }
    }

    static func webURL(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" ") else { return nil }
        if let url = URL(string: t), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) { return url }
        guard t.contains("."), let url = URL(string: "https://\(t)"), url.host != nil else { return nil }
        return url
    }


    func attention(from pane: WebPane, sound: String?) {
        SoundManager.shared.play(named: sound)
        if let host = pane.host, !host.isActive { host.attention = true }
        desktop.windowsChanged()
    }

    func paneUpdated(_ pane: WebPane) {
        if pane === activeWebPane { refreshNav() }
    }

    func offerToSave(host: String, username: String, password: String) {
        guard !config.neverSaveHosts.contains(host), !savePromptHosts.contains(host) else { return }
        let existing = Keychain.credential(forHost: host)
        if let existing, existing.password == password, username.isEmpty || existing.account == username { return }
        savePromptHosts.insert(host)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.savePromptHosts.remove(host) }
            let alert = NSAlert()
            alert.messageText = existing == nil ? "Save password for \(host)?" : "Update saved password for \(host)?"
            alert.informativeText = "AOL-OS stores it in your login keychain and fills it in next time."
            let field = NSTextField(string: username.isEmpty ? (existing?.account ?? "") : username)
            field.placeholderString = "Username"
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Not Now")
            alert.addButton(withTitle: "Never for This Site")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Keychain.save(host: host, account: field.stringValue, password: password)
            case .alertThirdButtonReturn:
                self.config.neverSaveHosts.append(host)
                ConfigStore.save(self.config)
            default:
                break
            }
        }
    }


    func refreshNav() {
        let nav = shell.navBar
        if let pane = activeWebPane {
            if nav.address.currentEditor() == nil {
                nav.address.stringValue = pane.webView.url?.absoluteString ?? ""
            }
            nav.back.isEnabled = signedOn && pane.webView.canGoBack
            nav.forward.isEnabled = signedOn && pane.webView.canGoForward
            nav.isLoading = pane.webView.isLoading
            shell.statusBar.status = pane.webView.isLoading ? "Loading \(pane.webView.url?.host ?? "")..." : "Done"
        } else {
            if nav.address.currentEditor() == nil { nav.address.stringValue = "" }
            nav.back.isEnabled = false
            nav.forward.isEnabled = false
            nav.isLoading = false
            shell.statusBar.status = signedOn ? "Done" : shell.statusBar.status
        }
    }

    func back() { activeWebPane?.webView.goBack() }
    func forward() { activeWebPane?.webView.goForward() }

    func reloadOrStop() {
        guard let wv = activeWebPane?.webView else { return }
        if wv.isLoading { wv.stopLoading() } else { wv.reload() }
    }

    func zoom(by delta: CGFloat?) {
        guard let wv = activeWebPane?.webView else { return }
        wv.pageZoom = delta.map { min(3, max(0.5, wv.pageZoom + $0)) } ?? 1
    }

    func closeActiveWindow() {
        if let w = desktop.activeWindow, w.closable { desktop.close(w) }
    }

    private func toolbarButton(_ title: String, _ symbol: String, _ colors: [NSColor], _ action: @escaping () -> Void) -> ToolbarButton {
        ToolbarButton(title: title, symbol: symbol, colors: colors, action: action)
    }

    private func buildChrome() {
        let blue = Theme.rgb(33, 96, 200), gold = Theme.rgb(232, 168, 0), green = Theme.rgb(40, 140, 70)
        let red = Theme.rgb(200, 50, 40), purple = Theme.rgb(88, 101, 242), gray = Theme.rgb(110, 110, 110)

        var musicButton: ToolbarButton!
        musicButton = toolbarButton("Music", "headphones", [red]) { [weak self] in
            guard let self else { return }
            let menu = NSMenu()
            menu.addItem(ActionItem("AOL Radio") { [weak self] in self?.openRadio() })
            menu.addItem(.separator())
            menu.addItem(ActionItem("YouTube Music") { [weak self] in self?.openService("ytmusic") })
            menu.addItem(ActionItem("Spotify Web Player") { [weak self] in self?.openService("spotify", web: true) })
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: musicButton.bounds.height), in: musicButton)
        }

        shell.toolbar.leftItems = [
            toolbarButton("Read", "envelope.fill", [blue]) { [weak self] in self?.openService("mail") },
            toolbarButton("Write", "square.and.pencil", [blue]) { [weak self] in self?.openService("write") },
            toolbarButton("IM", "figure.wave", [gold]) { [weak self] in self?.openService("im") },
            toolbarButton("Chat", "bubble.left.and.bubble.right.fill", [purple]) { [weak self] in self?.openService("chat") },
            musicButton,
            toolbarButton("Finance", "dollarsign.circle.fill", [.white, green]) { [weak self] in self?.openService("finance") },
            toolbarButton("Settings", "gearshape.fill", [gray]) { [weak self] in self?.openSettings() },
        ]
        shell.toolbar.rightItems = [
            toolbarButton("Keyword", "key.fill", [gold]) { [weak self] in self?.promptKeyword() },
            toolbarButton("Sign Off", "door.left.hand.open", [blue]) { [weak self] in self?.signOff() },
        ]

        let nav = shell.navBar
        nav.welcome.action = { [weak self] in self?.openWelcome() }
        nav.back.action = { [weak self] in self?.back() }
        nav.forward.action = { [weak self] in self?.forward() }
        nav.reload.action = { [weak self] in self?.reloadOrStop() }
        nav.address.onSubmit = { [weak self] text in self?.go(text) }
        nav.go.action = { [weak self] in self.map { $0.go($0.shell.navBar.address.stringValue) } }
        nav.search.action = { [weak self] in self?.promptKeyword() }

        shell.titleBar.minButton.action = { NSApp.hide(nil) }
        shell.titleBar.closeButton.action = { [weak self] in self?.quit() }

        shell.menuRow.setItems(MainMenu.rowItems(session: self))
        shell.setSignedOn(false)
    }
}
