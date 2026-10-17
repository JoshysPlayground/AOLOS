import AppKit
import WebKit

/// Forwards script messages without WKUserContentController retaining the pane.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebPane?

    init(_ target: WebPane) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

final class WebPane: FlippedView, WKNavigationDelegate, WKUIDelegate {
    struct PendingCredential {
        let host: String
        let username: String
        let password: String
        let date: Date
    }

    let webView: WKWebView
    let service: ServiceDef?
    /// Data store profile. Links opened from this pane in new windows reuse it.
    let profile: String
    weak var host: MDIWindow?
    weak var session: Session?
    private(set) var unread = 0
    private var sawTitle = false
    private var pendingCredential: PendingCredential?
    private var observations: [NSKeyValueObservation] = []

    static func configuration(for service: ServiceDef?, profile: String) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = DataStores.store(for: profile)
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        WebFeatures.set("PreferPageRenderingUpdatesNear60FPSEnabled", false, in: config.preferences)

        let controller = WKUserContentController()
        if service?.wantsHooks ?? true {
            controller.addUserScript(WKUserScript(source: Scripts.notificationShim, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
        }
        if service?.wantsHooks ?? true, let service, DiscordBridge.isDiscordHost(URL(string: service.url)?.host) {
            controller.addUserScript(WKUserScript(source: Scripts.discordBridge, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        if service?.wantsHooks ?? true, let service, MessengerBridge.isMessengerService(service.url) {
            controller.addUserScript(WKUserScript(source: Scripts.messengerBridge, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: Scripts.browserInput, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false, in: Scripts.browserWorld))
        if service?.wantsAutofill ?? true {
            controller.addUserScript(WKUserScript(source: Scripts.autofill, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Scripts.autofillWorld))
        }
        config.userContentController = controller
        return config
    }

    /// Pass `configuration` only for popups. WebKit requires the popup to use the opener's configuration,
    /// whose content controller already has this pane's message handlers registered.
    init(url: URL?, service: ServiceDef?, session: Session, profile: String = "browser",
         configuration: WKWebViewConfiguration? = nil) {
        let isPopup = configuration != nil
        let profile = service?.profile ?? profile
        let config = configuration ?? Self.configuration(for: service, profile: profile)
        self.webView = WKWebView(frame: .zero, configuration: config)
        Appearance.track(self.webView)
        self.service = service
        self.profile = profile
        self.session = session
        super.init(frame: .zero)

        if !isPopup {
            let handler = WeakMessageHandler(self)
            config.userContentController.add(handler, name: "aolos")
            config.userContentController.add(handler, contentWorld: Scripts.autofillWorld, name: "aolosAuth")
            config.userContentController.add(handler, contentWorld: Scripts.browserWorld, name: "aolosBrowser")
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        observations = [
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.titleChanged() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.urlChanged() }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.session?.paneUpdated($0) } }
            },
        ]

        if let url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url {
            webView.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Web windows open with a 1440x900 page area. The desktop shrinks them when it is smaller.
    static let windowSize = NSSize(width: 1440 + MDIWindow.border * 2,
                                   height: 900 + MDIWindow.titleHeight + MDIWindow.border * 2)


    static func unreadCount(in title: String) -> Int {
        guard let match = title.firstMatch(of: #/\((\d+)\)/#) else { return 0 }
        return Int(match.1) ?? 0
    }

    private func titleChanged() {
        let title = webView.title ?? ""
        if service == nil, !title.isEmpty { host?.title = title }

        let count = Self.unreadCount(in: title)
        if count != unread {
            let increased = count > unread
            unread = count
            // Mail plays on the first count too, which recreates the sign-on "You've got mail".
            if increased, let sound = service?.badgeSound, sawTitle || service?.id == "mail" {
                session?.attention(from: self, sound: sound)
            }
        }
        if !title.isEmpty { sawTitle = true }
        session?.paneUpdated(self)
    }

    private func urlChanged() {
        if let pending = pendingCredential {
            pendingCredential = nil
            if Date().timeIntervalSince(pending.date) < 30 {
                session?.offerToSave(host: pending.host, username: pending.username, password: pending.password)
            }
        }
        session?.paneUpdated(self)
    }


    func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let origin = message.frameInfo.securityOrigin

        if message.name == "aolosBrowser" {
            receiveBrowserInput(type, body, from: message.webView)
            return
        }

        switch type {
        case "notification":
            // Direct messages already play imrcv from the Buddy List, so the Discord window stays quiet.
            let quiet = (DiscordBridge.isDiscordHost(origin.host) && session?.discord.state == .ready)
                || (MessengerBridge.isMessengerHost(origin.host) && session?.messenger.state == .ready)
            session?.attention(from: self, sound: quiet ? nil : service?.notifySound ?? "notify")

        case let discordType where discordType.hasPrefix("discord."):
            guard message.frameInfo.isMainFrame, origin.protocol == "https",
                  DiscordBridge.isDiscordHost(origin.host) else { return }
            session?.discord.receive(discordType, body, from: self)

        case let messengerType where messengerType.hasPrefix("messenger."):
            guard message.frameInfo.isMainFrame, origin.protocol == "https",
                  MessengerBridge.isMessengerHost(origin.host) else { return }
            session?.messenger.receive(messengerType, body, from: self)

        case "credential":
            guard message.frameInfo.isMainFrame, origin.protocol == "https",
                  let password = body["password"] as? String, !password.isEmpty else { return }
            // Offer after the page navigates, which is when the login has most likely succeeded.
            pendingCredential = PendingCredential(host: origin.host, username: body["username"] as? String ?? "",
                                                  password: password, date: Date())

        case "needCredentials":
            guard message.frameInfo.isMainFrame, origin.protocol == "https",
                  let saved = Keychain.credential(forHost: origin.host) else { return }
            webView.callAsyncJavaScript("if (window.__aolosFill) window.__aolosFill(u, p);",
                                        arguments: ["u": saved.account, "p": saved.password],
                                        in: nil, in: Scripts.autofillWorld, completionHandler: nil)

        default:
            break
        }
    }

    /// Messages from `Scripts.browserInput`. A popup shares its opener's handlers, so act on the sending web view.
    private func receiveBrowserInput(_ type: String, _ body: [String: Any], from source: WKWebView?) {
        switch type {
        case "navigate":
            guard let source else { return }
            if body["direction"] as? String == "forward" { source.goForward() } else { source.goBack() }
        case "openLink":
            guard let text = body["url"] as? String, let url = URL(string: text), Self.isWeb(url) else { return }
            session?.openLink(url, from: self)
        default:
            break
        }
    }

    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Middle click or Command click on a link. WebKit reports the middle button as 2 or as the bit mask value 4.
    static func wantsNewWindow(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated
            && (action.buttonNumber == 2 || action.buttonNumber == 4 || action.modifierFlags.contains(.command))
    }


    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if Self.isWeb(url), Self.wantsNewWindow(navigationAction) {
            decisionHandler(.cancel)
            session?.openLink(url, from: self)
            return
        }
        switch scheme {
        case "http", "https", "about", "blob", "data", "file":
            decisionHandler(.allow)
        case "mailto":
            decisionHandler(.cancel)
            session?.compose(mailto: url)
        default:
            decisionHandler(.cancel)
        }
    }


    /// Without this a failed page load leaves the window blank. Cancelled loads and policy interruptions
    /// (a link opened elsewhere, a download) are expected and stay quiet.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        webView.loadHTMLString(Self.errorPage(error.localizedDescription, url: url), baseURL: nil)
    }

    static func errorPage(_ message: String, url: URL?) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let address = url.map { escape($0.absoluteString) } ?? ""
        return """
        <!doctype html><meta charset="utf-8"><title>Page not available</title>
        <body style="font: 13px -apple-system, sans-serif; margin: 40px; color: #222">
        <h2 style="font-size: 16px">This page could not be opened.</h2>
        <p>\(escape(message))</p><p style="color: #666; word-break: break-all">\(address)</p>
        """
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A target=_blank link becomes a full browser window. Scripted popups such as sign-in windows keep their opener.
        if navigationAction.navigationType == .linkActivated, windowFeatures.width == nil, windowFeatures.height == nil,
           let url = navigationAction.request.url, Self.isWeb(url) {
            session?.openLink(url, from: self)
            return nil
        }
        return session?.openPopup(configuration: configuration, from: self, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let host { host.desktop?.close(host) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
