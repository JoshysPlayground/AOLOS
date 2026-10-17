import AppKit

/// One window from the last session, with enough to open it again where it was.
struct SavedWindow: Codable, Equatable {
    enum Kind: String, Codable {
        case welcome, settings, mailbox, radio, pictures, buddyList, chatRooms, favorites, safety
        case service, browser, im, groupChat, room
        /// Claude Code or a shell. `id` is the TerminalLaunch kind, `url` the folder.
        case terminal
    }

    var kind: Kind
    /// Service ID, or the buddy, group chat or room ID.
    var id: String?
    var name: String?
    /// Server name for a chat room.
    var detail: String?
    var url: String?
    var profile: String?
    var frame: CGRect
    var minimized = false
    var maximized = false
    var active = false

    /// IMs, group chats and rooms wait for their chat service before they can open.
    var needsDiscord: Bool { [.im, .groupChat, .room].contains(kind) }
}

/// Window layouts per screen name, kept apart from config.json in Application Support/AOL-OS/windows.json.
enum WindowStore {
    static var defaultURL: URL { AppPaths.support.appendingPathComponent("windows.json") }

    static func load(_ screenName: String, from url: URL = defaultURL) -> [SavedWindow] {
        loadAll(url)[screenName.lowercased()] ?? []
    }

    static func save(_ windows: [SavedWindow], for screenName: String, to url: URL = defaultURL) {
        var all = loadAll(url)
        all[screenName.lowercased()] = windows
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadAll(_ url: URL) -> [String: [SavedWindow]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [SavedWindow]].self, from: data)) ?? [:]
    }

    /// Keeps a saved frame on a desktop that may be smaller than the one it was saved on.
    static func fit(_ frame: CGRect, in bounds: CGRect, minSize: CGSize) -> CGRect {
        var f = frame
        f.size.width = min(max(f.width, minSize.width), bounds.width)
        f.size.height = min(max(f.height, minSize.height), bounds.height)
        f.origin.x = min(max(0, f.minX), max(0, bounds.width - f.width))
        f.origin.y = min(max(0, f.minY), max(0, bounds.height - f.height))
        return f.integral
    }
}

@MainActor
final class WindowRestoreState {
    /// Conversations from the last session still waiting for their chat service.
    var pending: [SavedWindow] = []
    /// Plain browser windows, so popups opened by a page are not brought back.
    let browserWindows = NSHashTable<MDIWindow>.weakObjects()
    var saveTask: Task<Void, Never>?
    var restoring = false
}

extension Session {
    func setUpWindowRestore() {
        let onReady = discord.onReady
        discord.onReady = { [weak self] in
            onReady?()
            self?.restorePendingConversations()
        }
        let onChange = discord.onChange
        discord.onChange = { [weak self] in
            onChange?()
            self?.restorePendingConversations()
        }
        let messengerReady = messenger.onReady
        messenger.onReady = { [weak self] in
            messengerReady?()
            self?.restorePendingConversations()
        }
        let messengerChange = messenger.onChange
        messenger.onChange = { [weak self] in
            messengerChange?()
            self?.restorePendingConversations()
        }
        let desktopChange = desktop.onChange
        desktop.onChange = { [weak self] in
            desktopChange?()
            self?.scheduleWindowSave()
        }
    }

    /// Saves now. Called on sign off and quit, and a second after windows open, close, move to front or minimize.
    func saveWindowLayout() {
        windowRestore.saveTask?.cancel()
        windowRestore.saveTask = nil
        guard signedOn, !windowRestore.restoring else { return }
        let open = desktop.windows.sorted { $0.zIndex < $1.zIndex }.compactMap(savedWindow(for:))
        WindowStore.save(open + windowRestore.pending, for: config.screenName)
    }

    func scheduleWindowSave() {
        guard signedOn, !windowRestore.restoring else { return }
        windowRestore.saveTask?.cancel()
        windowRestore.saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveWindowLayout()
        }
    }

    /// Reopens the last session's windows for this screen name. Returns false when there is nothing to restore.
    @discardableResult
    func restoreWindowLayout() -> Bool {
        let saved = WindowStore.load(config.screenName)
        guard !saved.isEmpty else { return false }
        windowRestore.restoring = true
        var active: MDIWindow?
        for item in saved {
            if item.needsDiscord {
                windowRestore.pending.append(item)
            } else if let w = reopen(item), item.active {
                active = w
            }
        }
        windowRestore.restoring = false
        if let active, !active.isHidden { desktop.activate(active) }
        if !windowRestore.pending.isEmpty {
            ensureDiscordPane()
            if windowRestore.pending.contains(where: { MessengerID.owns($0.id ?? "") }) { ensureMessengerPane() }
            restorePendingConversations()
        }
        return true
    }

    func restorePendingConversations() {
        guard signedOn, !windowRestore.pending.isEmpty else { return }
        let items = windowRestore.pending.filter { chatService(for: $0.id ?? "").myID != nil }
        guard !items.isEmpty else { return }
        windowRestore.pending.removeAll { item in items.contains(item) }
        let previous = desktop.activeWindow
        windowRestore.restoring = true
        var active: MDIWindow?
        for item in items {
            if let w = reopen(item), item.active { active = w }
        }
        windowRestore.restoring = false
        if let w = active ?? previous, !w.isHidden { desktop.activate(w) }
        scheduleWindowSave()
    }

    func forgetPendingWindows() {
        windowRestore.pending = []
        windowRestore.saveTask?.cancel()
        windowRestore.saveTask = nil
    }

    func savedWindow(for w: MDIWindow) -> SavedWindow? {
        // A maximized window keeps the frame it un-maximizes to, so restoring it later goes back to the right size.
        var item = SavedWindow(kind: .welcome, frame: w.isMaximized ? w.restoreFrame : w.frame, minimized: w.isHidden,
                               maximized: w.isMaximized, active: w.isActive)
        switch w.content {
        case is WelcomePane: item.kind = .welcome
        case is SettingsView: item.kind = .settings
        case is MailboxView: item.kind = .mailbox
        case is RadioView: item.kind = .radio
        case is PicturesView: item.kind = .pictures
        case is BuddyListView: item.kind = .buddyList
        case is ChatRoomsView: item.kind = .chatRooms
        case is FavoritesView: item.kind = .favorites
        case is SafetyView: item.kind = .safety
        case let pane as TerminalPane:
            item.kind = .terminal
            item.id = pane.launch.kind.rawValue
            item.url = pane.launch.kind == .claude ? pane.launch.directory : pane.currentDirectory
        case let view as InstantMessageView:
            guard let target = view.target else { return nil }
            item.id = target.id
            if view.tracksSpeakers {
                item.kind = .room
                item.name = view.buddyName.hasPrefix("#") ? String(view.buddyName.dropFirst()) : view.buddyName
                if let range = w.title.range(of: " - ") { item.detail = String(w.title[range.upperBound...]) }
            } else {
                item.kind = view.isGroup ? .groupChat : .im
                item.name = view.buddyName
            }
        case let pane as WebPane:
            if let service = pane.service, serviceWindows[service.id] === w {
                item.kind = .service
                item.id = service.id
            } else if windowRestore.browserWindows.contains(w),
                      let url = pane.webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                item.kind = .browser
                item.url = url.absoluteString
                item.profile = pane.profile
            } else {
                return nil
            }
        default:
            // Mail messages, Write Mail, photo viewers and popups belong to the moment they were opened in.
            return nil
        }
        return item
    }

    private func reopen(_ item: SavedWindow) -> MDIWindow? {
        let before = Set(desktop.windows.map(ObjectIdentifier.init))
        switch item.kind {
        case .welcome: openWelcome()
        case .settings: openSettings()
        case .mailbox: openMailbox()
        case .radio: openRadio()
        case .pictures: openPictures()
        case .buddyList: openBuddyList()
        case .chatRooms: openChatRooms()
        case .favorites: openFavorites()
        case .safety: openSafety()
        case .service:
            guard let id = item.id, config.service(id) != nil else { return nil }
            openService(id, web: true)
        case .browser:
            guard let url = item.url.flatMap(URL.init(string:)) else { return nil }
            openBrowser(url, profile: item.profile ?? "browser")
        case .terminal:
            // Claude Code picks its last conversation in that folder back up.
            if item.id == TerminalLaunch.Kind.shell.rawValue {
                openTerminal(in: item.url)
            } else {
                openTerminalWindow(TerminalLaunch(kind: .claude, directory: item.url ?? NSHomeDirectory(), resume: true))
            }
        case .im:
            guard let id = item.id else { return nil }
            openIM(with: chatService(for: id).buddy(id) ?? Buddy(id: id, name: item.name ?? id, presence: .offline))
        case .groupChat:
            guard let id = item.id else { return nil }
            openGroupChat(chatService(for: id).group(id) ?? GroupChat(id: id, name: item.name ?? "Group Chat", members: []))
        case .room:
            guard let id = item.id,
                  let room = ChatRoom(json: ["id": id, "name": item.name ?? id]),
                  let server = ChatServer(json: ["id": item.detail ?? "server", "name": item.detail ?? ""]) else { return nil }
            openChatRoom(room, in: server)
        }
        // Opening the Buddy List can open the Discord pane first, so the window asked for is the last one added.
        let window = desktop.windows.last { !before.contains(ObjectIdentifier($0)) }
            ?? desktop.windows.first { w in
                savedWindow(for: w).map { $0.kind == item.kind && $0.id == item.id } ?? false
            }
        guard let window else { return nil }
        place(window, item)
        return window
    }

    private func place(_ w: MDIWindow, _ item: SavedWindow) {
        w.setMaximizedFrame(WindowStore.fit(item.frame, in: desktop.bounds, minSize: w.minSize))
        if item.maximized, !w.isMaximized { w.toggleMaximize() }
        if item.minimized {
            if !w.isHidden { desktop.minimize(w) }
        } else if w.isHidden {
            desktop.restore(w)
        }
    }
}
