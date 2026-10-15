import AppKit
import WebKit

@MainActor
enum RemoteContentBlocker {
    private(set) static var ruleList: WKContentRuleList?

    static func prepare() {
        guard ruleList == nil else { return }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "AOLOSBlockRemoteContent", encodedContentRuleList: rules) { list, _ in
            MainActor.assumeIsolated { ruleList = list }
        }
    }
}

final class MessageHeaderView: FlippedView {
    var subject = "" { didSet { needsDisplay = true } }
    var lines: [(String, String)] = [] { didSet { needsDisplay = true } }

    var preferredHeight: CGFloat { 40 + CGFloat(lines.count) * 18 + 8 }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient([Theme.rgb(255, 255, 255), Theme.rgb(238, 234, 220)], in: bounds)
        Theme.chromeShade.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        drawText(subject, font: Theme.ui(15, bold: true), color: Theme.text,
                 in: NSRect(x: 12, y: 10, width: bounds.width - 24, height: 22))
        var y: CGFloat = 40
        for (label, value) in lines {
            drawText(label, font: Theme.ui(11, bold: true), color: Theme.mutedText,
                     in: NSRect(x: 12, y: y, width: 70, height: 16), align: .right)
            drawText(value, font: Theme.ui(12), color: Theme.text,
                     in: NSRect(x: 90, y: y, width: bounds.width - 102, height: 16))
            y += 18
        }
    }
}

/// Shows one message. Scripts never run and remote content stays blocked until the reader asks for it.
final class MessageView: FlippedView, WKNavigationDelegate {
    enum Action { case reply, replyAll, forward, keepAsNew, delete }

    var onAction: ((Action) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    private(set) var message: MailMessage?

    private let header = MessageHeaderView()
    private let webView: WKWebView
    private let bar = ButtonBar()
    private let showImages = ChromeButton(title: "Show Images", symbol: "photo")
    private var imagesAllowed = false

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        webView.navigationDelegate = self

        let specs: [(Action, String, String)] = [
            (.reply, "Reply", "arrowshape.turn.up.left"), (.replyAll, "Reply All", "arrowshape.turn.up.left.2"),
            (.forward, "Forward", "arrowshape.turn.up.right"), (.keepAsNew, "Keep As New", "envelope.badge"),
            (.delete, "Delete", "trash"),
        ]
        bar.buttons = specs.map { action, title, symbol in
            ChromeButton(title: title, symbol: symbol) { [weak self] in self?.onAction?(action) }
        }
        bar.buttons.forEach { $0.isEnabled = false }
        showImages.isHidden = true
        showImages.action = { [weak self] in self?.allowImages() }

        [header, webView, bar, showImages].forEach(addSubview)
        header.subject = "Loading message..."
        webView.loadHTMLString("", baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = header.preferredHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        let w = showImages.preferredWidth + 8
        showImages.frame = NSRect(x: bounds.width - w - 10, y: h - 32, width: w, height: 24)
        bar.frame = NSRect(x: 0, y: bounds.height - 42, width: bounds.width, height: 42)
        webView.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bar.frame.minY - h))
    }

    func show(_ message: MailMessage, isSent: Bool) {
        self.message = message
        header.subject = message.subject
        var lines = [("From:", message.from), ("To:", message.to)]
        if !message.cc.isEmpty { lines.append(("Cc:", message.cc)) }
        lines.append(("Date:", message.date))
        if !message.attachments.isEmpty { lines.append(("Attached:", message.attachments.joined(separator: ", "))) }
        header.lines = lines
        bar.buttons.forEach { $0.isEnabled = true }
        bar.buttons[3].isEnabled = !isSent
        showImages.isHidden = !message.hasRemoteContent
        needsLayout = true
        load()
    }

    func showError(_ text: String) {
        header.subject = "This message could not be opened"
        header.lines = [("Reason:", text)]
        needsLayout = true
    }

    private func allowImages() {
        imagesAllowed = true
        showImages.isHidden = true
        load()
    }

    private func load() {
        guard let message else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if !imagesAllowed, let rules = RemoteContentBlocker.ruleList { controller.add(rules) }
        webView.loadHTMLString(message.html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" { onOpenLink?(url) }
            return
        }
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
}

final class ComposeView: FlippedView {
    var onSend: (() -> Void)?

    let toField = NSTextField()
    let ccField = NSTextField()
    let subjectField = NSTextField()
    let textView: NSTextView
    private let scroll: NSScrollView
    private let bar = ButtonBar()
    private let sendButton = ChromeButton(title: "Send Now", symbol: "paperplane.fill", prominent: true)

    init(to: String, cc: String, subject: String, body: String) {
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init(frame: .zero)

        for (field, value) in [(toField, to), (ccField, cc), (subjectField, subject)] {
            field.stringValue = value
            field.font = Theme.ui(12)
            addSubview(field)
        }
        toField.placeholderString = "name@example.com, another@example.com"
        textView.string = body
        textView.font = Theme.ui(13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.borderType = .bezelBorder
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        sendButton.action = { [weak self] in self?.onSend?() }
        bar.buttons = [sendButton]
        [scroll, bar].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredFirstResponder: NSView { toField.stringValue.isEmpty ? toField : textView }

    override func layout() {
        super.layout()
        let x: CGFloat = 76
        for (i, field) in [toField, ccField, subjectField].enumerated() {
            field.frame = NSRect(x: x, y: 10 + CGFloat(i) * 30, width: bounds.width - x - 12, height: 22)
        }
        bar.frame = NSRect(x: 0, y: bounds.height - 42, width: bounds.width, height: 42)
        scroll.frame = NSRect(x: 10, y: 102, width: bounds.width - 20, height: max(0, bar.frame.minY - 110))
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        for (i, label) in ["Send To:", "Copy To:", "Subject:"].enumerated() {
            drawText(label, font: Theme.ui(11, bold: true), color: Theme.text,
                     in: NSRect(x: 4, y: 12 + CGFloat(i) * 30, width: 66, height: 18), align: .right)
        }
    }

    func setBusy(_ busy: Bool) {
        sendButton.isEnabled = !busy
        sendButton.title = busy ? "Sending..." : "Send Now"
        bar.statusLabel.stringValue = busy ? "Sending your mail..." : ""
    }

    func showStatus(_ text: String) {
        bar.statusLabel.stringValue = text
    }
}
