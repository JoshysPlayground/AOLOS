import AppKit
import WebKit

/// Browser behavior shared by every web window: mouse and keyboard navigation, links in new windows, and Favorites.
extension Session {
    func setUpBrowserInput() {
        browserMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handleBrowserInput(event) ? nil : event
        }
    }

    /// Returns true when the event was used and should not reach the page.
    private func handleBrowserInput(_ event: NSEvent) -> Bool {
        guard signedOn, event.window === shell.window, NSApp.modalWindow == nil else { return false }
        switch event.type {
        case .otherMouseDown, .otherMouseUp:
            // AppKit numbers the mouse side buttons 3 (back) and 4 (forward).
            guard event.buttonNumber == 3 || event.buttonNumber == 4, let pane = webPane(under: event) else { return false }
            if event.type == .otherMouseDown {
                if event.buttonNumber == 3 { pane.webView.goBack() } else { pane.webView.goForward() }
            }
            return true
        case .keyDown:
            return handleBrowserKey(event)
        case .scrollWheel:
            // A notched mouse wheel glides like a trackpad. Only over a web window's page, not the AOL chrome.
            guard quickLaunch == nil else { return false }
            let p = desktop.convert(event.locationInWindow, from: nil)
            guard desktop.bounds.contains(p),
                  let pane = desktop.visibleWindows.last(where: { $0.frame.contains(p) })?.content as? WebPane,
                  pane.bounds.contains(pane.convert(event.locationInWindow, from: nil)) else { return false }
            return smoothScroller.handle(event, in: pane.webView)
        default:
            return false
        }
    }

    /// The web window under the pointer, or the active one when the pointer is over the AOL chrome.
    private func webPane(under event: NSEvent) -> WebPane? {
        let p = desktop.convert(event.locationInWindow, from: nil)
        guard desktop.bounds.contains(p) else { return activeWebPane }
        return desktop.visibleWindows.last { $0.frame.contains(p) }?.content as? WebPane
    }

    private func handleBrowserKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let pane = activeWebPane

        if event.keyCode == 96, flags.isEmpty, pane != nil {
            reloadOrStop()
            return true
        }
        if flags == .command {
            switch key {
            case "[": back(); return pane != nil
            case "]": forward(); return pane != nil
            case "l": focusAddressBar(); return true
            case "t": toggleQuickLaunch(); return true
            case "d": addFavorite(); return true
            default: break
            }
        }
        // Cmd or Option with Left and Right navigate unless a text field has focus. The page script covers web views.
        if (flags == .command || flags == .option), event.keyCode == 123 || event.keyCode == 124, let pane {
            let responder = shell.window?.firstResponder
            guard !(responder is NSText), !(responder is WKWebView) else { return false }
            if event.keyCode == 123 { pane.webView.goBack() } else { pane.webView.goForward() }
            return true
        }
        return false
    }

    func focusAddressBar() {
        guard signedOn else { return }
        shell.window?.makeFirstResponder(shell.navBar.address)
        shell.navBar.address.currentEditor()?.selectAll(nil)
    }

    /// Opens a link in its own browser window. Keeps the source page's profile so its logins carry over.
    /// A middle click can arrive from both the page script and WebKit, so a repeat within a second is dropped.
    func openLink(_ url: URL, from pane: WebPane) {
        guard signedOn else { return }
        if let last = lastOpenedLink, last.url == url, Date().timeIntervalSince(last.date) < 1 { return }
        lastOpenedLink = (url, Date())
        openBrowser(url, profile: pane.profile)
    }


    /// The page in the active window when it is an ordinary web address.
    var currentPage: (title: String, url: URL)? {
        guard let wv = activeWebPane?.webView, let url = wv.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let title = (wv.title?.isEmpty == false ? wv.title : nil) ?? url.host ?? url.absoluteString
        return (title, url)
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let address = url?.absoluteString else { return false }
        return config.favorites.contains { $0.url == address }
    }

    /// Saves the current page, or offers to remove it when it is already a Favorite.
    func addFavorite() {
        guard signedOn else { return }
        guard let page = currentPage else { NSSound.beep(); return }
        let address = page.url.absoluteString
        if let index = config.favorites.firstIndex(where: { $0.url == address }) {
            let alert = NSAlert()
            alert.messageText = "\"\(config.favorites[index].title)\" is already in your Favorite Places."
            alert.informativeText = address
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Remove from Favorites")
            if alert.runModal() == .alertSecondButtonReturn {
                updateConfig { $0.favorites.remove(at: index) }
                favoritesChanged()
            }
            return
        }
        guard let title = Prompt.text(title: "Add to Favorite Places", message: address,
                                      initial: page.title, confirm: "Add") else { return }
        updateConfig { $0.favorites.append(Favorite(title: title, url: address)) }
        favoritesChanged()
    }

    /// Opens in the active browser window, or a new one when the active window is a service or not a web page.
    func openFavorite(_ favorite: Favorite) {
        guard signedOn, let url = URL(string: favorite.url) else { return }
        if let pane = activeWebPane, pane.service == nil {
            pane.webView.load(URLRequest(url: url))
        } else {
            openBrowser(url)
        }
    }

    func favoritesMenu() -> NSMenu {
        let menu = NSMenu(title: "Favorites")
        menu.autoenablesItems = false
        let add = ActionItem("Add to Favorites") { [weak self] in self?.addFavorite() }
        add.isEnabled = signedOn && currentPage != nil
        add.image = Icons.symbol("heart", size: 13, colors: [Theme.aolBlue])
        menu.addItem(add)
        let manage = ActionItem("Manage Favorite Places...") { [weak self] in self?.openFavorites() }
        manage.isEnabled = signedOn
        menu.addItem(manage)
        menu.addItem(.separator())
        if config.favorites.isEmpty {
            let empty = NSMenuItem(title: "No Favorite Places yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for favorite in config.favorites {
            let title = favorite.title.count > 60 ? String(favorite.title.prefix(57)) + "..." : favorite.title
            let item = ActionItem(title) { [weak self] in self?.openFavorite(favorite) }
            item.toolTip = favorite.url
            item.image = Icons.symbol("heart.fill", size: 13, colors: [Theme.rgb(204, 40, 40)])
            item.isEnabled = signedOn
            menu.addItem(item)
        }
        return menu
    }

    func openFavorites() {
        guard signedOn else { return }
        if let w = favoritesWindow, w.superview != nil { desktop.activate(w); return }
        let view = FavoritesView(favorites: config.favorites)
        view.onChange = { [weak self] list in
            self?.updateConfig { $0.favorites = list }
            self?.refreshNav()
        }
        view.onOpen = { [weak self] favorite in self?.openFavorite(favorite) }
        let window = MDIWindow(title: "Favorite Places", icon: Icons.symbol("heart.fill", colors: [.white]), content: view)
        window.focusView = view.table
        window.minSize = NSSize(width: 420, height: 240)
        window.onClose = { [weak self] in self?.favoritesWindow = nil; self?.favoritesView = nil }
        favoritesWindow = window
        favoritesView = view
        desktop.add(window, size: NSSize(width: 640, height: 420), centered: true)
    }

    func favoritesChanged() {
        favoritesView?.reload(config.favorites)
        refreshNav()
    }
}
