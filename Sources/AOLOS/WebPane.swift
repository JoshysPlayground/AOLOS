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
    weak var host: MDIWindow?
    weak var session: Session?
    private(set) var unread = 0
    private var sawTitle = false
    private var pendingCredential: PendingCredential?
    private var observations: [NSKeyValueObservation] = []

    static func configuration(for service: ServiceDef?) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = DataStores.store(for: service?.profile ?? "browser")
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let controller = WKUserContentController()
        if service?.wantsHooks ?? true {
            controller.addUserScript(WKUserScript(source: Scripts.notificationShim, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
        }
        if service?.wantsAutofill ?? true {
            controller.addUserScript(WKUserScript(source: Scripts.autofill, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Scripts.autofillWorld))
        }
        config.userContentController = controller
        return config
    }

    /// Pass `configuration` only for popups. WebKit requires the popup to use the opener's configuration,
    /// whose content controller already has this pane's message handlers registered.
    init(url: URL?, service: ServiceDef?, session: Session, configuration: WKWebViewConfiguration? = nil) {
        let isPopup = configuration != nil
        let config = configuration ?? Self.configuration(for: service)
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.service = service
        self.session = session
        super.init(frame: .zero)

        if !isPopup {
            let handler = WeakMessageHandler(self)
            config.userContentController.add(handler, name: "aolos")
            config.userContentController.add(handler, contentWorld: Scripts.autofillWorld, name: "aolosAuth")
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

        if let url { webView.load(URLRequest(url: url)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }


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

        switch type {
        case "notification":
            session?.attention(from: self, sound: service?.notifySound ?? "notify")

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


    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
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


    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        session?.openPopup(configuration: configuration, from: self, features: windowFeatures)
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
