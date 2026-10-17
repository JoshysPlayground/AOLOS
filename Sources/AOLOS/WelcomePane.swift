import AppKit
import WebKit

final class WelcomeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: Session?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let id = body["open"] as? String { session?.openService(id) }
        if let text = body["keyword"] as? String { session?.go(text) }
    }
}

/// The Welcome screen. Local HTML that sends `open` and `keyword` messages back to the session.
final class WelcomePane: FlippedView, WKNavigationDelegate {
    let webView: WKWebView
    private let handler = WelcomeMessageHandler()
    private var mailState: (String, Bool)?
    private var loaded = false

    init(session: Session, screenName: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(handler, name: "welcome")
        webView = WKWebView(frame: .zero, configuration: config)
        Appearance.track(webView)
        super.init(frame: .zero)
        handler.session = session
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        webView.loadHTMLString(Self.html(screenName: screenName), baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func setMailState(_ text: String, hasMail: Bool) {
        if let current = mailState, current.0 == text, current.1 == hasMail { return }
        mailState = (text, hasMail)
        if loaded { applyMailState() }
    }

    private func applyMailState() {
        guard let (text, hasMail) = mailState else { return }
        webView.callAsyncJavaScript("window.setMail && setMail(text, has)",
                                    arguments: ["text": text, "has": hasMail], in: nil, in: .page, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyMailState()
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func html(screenName: String) -> String {
        let name = escape(screenName)
        return #"""
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          * { box-sizing: border-box; }
          body { margin: 0; font: 13px Tahoma, Verdana, sans-serif; color: #1a1a1a; background: #f4f1e6; }
          a { color: #1446aa; text-decoration: none; cursor: pointer; }
          a:hover { text-decoration: underline; }
          .top { display: flex; align-items: center; justify-content: space-between;
                 padding: 10px 16px; background: linear-gradient(#ffffff, #e7e2cf); border-bottom: 1px solid #c9c3ab; }
          .brand { font: bold 34px Helvetica, Arial, sans-serif; color: #0054a6; letter-spacing: -1px; }
          .search { display: flex; gap: 6px; }
          .search input { width: 320px; padding: 5px 7px; border: 1px solid #7f9db9; font: 13px Tahoma; }
          .search button { padding: 4px 14px; font: bold 12px Tahoma; border: 1px solid #6d9a1e;
                           background: linear-gradient(#c8ec7c, #8cc63f); border-radius: 2px; cursor: pointer; }
          .grid { display: grid; grid-template-columns: 1.35fr 1fr; gap: 12px; padding: 12px 16px; }
          .panel { background: #fff; border: 1px solid #c9c3ab; }
          .panel h2 { margin: 0; padding: 6px 10px; font-size: 13px; color: #1446aa;
                      background: linear-gradient(#f7f4ea, #e9e4d1); border-bottom: 1px solid #c9c3ab; }
          .hello { padding: 14px 16px; }
          .hello h1 { margin: 0 0 4px; font-size: 22px; }
          .hello .date { color: #666; }
          .mail { display: flex; align-items: center; gap: 14px; margin-top: 14px; padding: 12px;
                  background: #eef3fc; border: 1px solid #b9cbe8; cursor: pointer; }
          .mail .box { width: 54px; height: 44px; border-radius: 6px 6px 2px 2px; background: #2b62c4; position: relative; }
          .mail .box::after { content: ""; position: absolute; right: -6px; top: 4px; width: 6px; height: 22px; background: #d92b2b; }
          .mail.has .box::after { top: -14px; }
          .mail strong { font-size: 16px; }
          .tiles { display: grid; grid-template-columns: repeat(3, 1fr); }
          .tile { padding: 14px 6px; text-align: center; border-right: 1px solid #ece7d6; border-bottom: 1px solid #ece7d6; cursor: pointer; }
          .tile:hover { background: #fdf6dc; }
          .tile .dot { width: 34px; height: 34px; margin: 0 auto 6px; border-radius: 8px; color: #fff;
                       font: bold 17px Helvetica, Arial; line-height: 34px; }
          .links { columns: 3; padding: 8px 12px; }
          .links a { display: block; padding: 3px 0; }
        </style></head>
        <body>
          <div class="top">
            <div class="brand">AOL-OS</div>
            <form class="search" onsubmit="go(event)">
              <input id="kw" placeholder="Search or type a Keyword" autocomplete="off">
              <button>Search</button>
            </form>
          </div>
          <div class="grid">
            <div class="panel">
              <h2>Welcome</h2>
              <div class="hello">
                <h1>Welcome, \#(name)!</h1>
                <div class="date" id="date"></div>
                <div class="mail" id="mail" onclick="openId('mail')">
                  <div class="box"></div>
                  <div><strong id="mailTitle">Checking mail...</strong><br><a>Open Mailbox</a></div>
                </div>
              </div>
            </div>
            <div class="panel">
              <h2>Go To</h2>
              <div class="tiles">
                <div class="tile" onclick="openId('mail')"><div class="dot" style="background:#2b62c4">M</div>Mail</div>
                <div class="tile" onclick="openId('im')"><div class="dot" style="background:#e3a400">IM</div>Instant Message</div>
                <div class="tile" onclick="openId('chat')"><div class="dot" style="background:#5865f2">C</div>Chat</div>
                <div class="tile" onclick="openId('ytmusic')"><div class="dot" style="background:#d62d2d">&#9835;</div>YouTube Music</div>
                <div class="tile" onclick="openId('radio')"><div class="dot" style="background:#1db954">R</div>AOL Radio</div>
                <div class="tile" onclick="openId('finance')"><div class="dot" style="background:#2e8b57">$</div>Finance</div>
              </div>
            </div>
          </div>
          <div class="grid" style="grid-template-columns:1fr; padding-top:0">
            <div class="panel">
              <h2>Can't Find It? Keywords</h2>
              <div class="links">
                <a onclick="kw('mail')">Mail</a><a onclick="kw('write')">Write</a><a onclick="kw('discord')">Discord</a>
                <a onclick="kw('slack')">Slack</a><a onclick="kw('music')">Music</a><a onclick="kw('spotify')">Spotify</a>
                <a onclick="kw('bank')">Bank</a><a onclick="kw('settings')">Settings</a><a onclick="kw('news.google.com')">News</a>
              </div>
            </div>
          </div>
          <script>
            const post = (m) => window.webkit.messageHandlers.welcome.postMessage(m);
            const openId = (id) => post({ open: id });
            const kw = (text) => post({ keyword: text });
            function go(e) { e.preventDefault(); const v = document.getElementById('kw').value.trim(); if (v) kw(v); }
            function setMail(text, has) {
              document.getElementById('mailTitle').textContent = text;
              document.getElementById('mail').classList.toggle('has', has);
            }
            document.getElementById('date').textContent =
              new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
          </script>
        </body></html>
        """#
    }
}
