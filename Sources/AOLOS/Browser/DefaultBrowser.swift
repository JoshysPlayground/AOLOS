import AppKit
import UniformTypeIdentifiers

/// AOL-OS as the Mac's web browser. macOS sends it every http and https link opened outside the app.
enum DefaultBrowser {
    static let schemes = ["http", "https"]
    private static let previousKey = "previousBrowser"

    /// LaunchServices only registers handlers for an app bundle, so the `swift build` binary cannot be the default.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isDefault: Bool {
        guard isBundled, let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.aol.com")!) else { return false }
        return isSelf(handler)
    }

    /// macOS shows its own confirmation before switching browsers. The browser being replaced is kept for sign in pages.
    @MainActor
    static func makeDefault() async throws {
        if let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.aol.com")!),
           !isSelf(current), let id = Bundle(url: current)?.bundleIdentifier {
            UserDefaults.standard.set(id, forKey: previousKey)
        }
        let app = Bundle.main.bundleURL
        for scheme in schemes {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
        }
        try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
    }

    /// Opens a page in a browser other than AOL-OS. Google blocks sign in inside embedded web views,
    /// so OAuth pages must not come back here once AOL-OS is the default browser.
    static func openElsewhere(_ url: URL) {
        let others = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { !isSelf($0) }
        let ids = others.map { Bundle(url: $0)?.bundleIdentifier }
        let preferred = [UserDefaults.standard.string(forKey: previousKey), "com.apple.Safari"]
        let pick = preferred.lazy.compactMap { id in id.flatMap { ids.firstIndex(of: $0) } }.first.map { others[$0] } ?? others.first
        guard let pick else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: pick, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The page to open for a URL macOS handed over, or nil for anything AOL-OS does not browse.
    static func page(for url: URL) -> URL? {
        if url.isFileURL { return url }
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func isSelf(_ app: URL) -> Bool {
        if app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return true }
        guard let mine = Bundle.main.bundleIdentifier else { return false }
        return Bundle(url: app)?.bundleIdentifier == mine
    }
}

extension Session {
    /// Links from other apps. They wait for sign on, then open after the restored windows so they land on top.
    func openExternal(_ urls: [URL]) {
        let pages = urls.compactMap(DefaultBrowser.page(for:))
        guard !pages.isEmpty else { return }
        if let window = shell.window, window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        guard signedOn else {
            pendingLinks += pages
            let host = pages.last?.host ?? pages.last?.lastPathComponent ?? "your page"
            shell.statusBar.status = pendingLinks.count == 1 ? "Sign on to open \(host)" : "Sign on to open \(pendingLinks.count) pages"
            return
        }
        for url in pages { openBrowser(url) }
    }

    func openPendingLinks() {
        let pages = pendingLinks
        pendingLinks = []
        for url in pages { openBrowser(url) }
    }

    func makeDefaultBrowser() {
        guard DefaultBrowser.isBundled else {
            let alert = NSAlert()
            alert.messageText = "AOL-OS can only be the default browser when it runs as an app."
            alert.informativeText = "Run make install to build AOL-OS.app into Applications, then open it from there."
            alert.runModal()
            return
        }
        Task { [weak self] in
            do {
                try await DefaultBrowser.makeDefault()
            } catch {
                let alert = NSAlert()
                alert.messageText = "AOL-OS is not your default browser."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self?.settingsView?.refreshBrowserStatus()
        }
    }
}
