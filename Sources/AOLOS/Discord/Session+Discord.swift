import AppKit

extension Session {
    func setUpDiscord() {
        discord.onChange = { [weak self] in self?.refreshBuddies() }
        discord.onBuddyChange = { [weak self] buddy, change in
            guard let self, !self.hiddenBuddyIDs.contains(buddy.id) else { return }
            self.shell.statusBar.status = "\(buddy.name) \(change.verb)."
        }
        discord.onMessage = { [weak self] userId, message in self?.receiveIM(from: userId, message) }
        discord.onGroupMessage = { [weak self] chat, message in self?.receiveGroupMessage(chat, message) }
        discord.onRoomMessage = { [weak self] channelId, message in self?.receiveRoomMessage(channelId, message) }
        discord.onReactions = { [weak self] channelId, messageId, reactions in
            self?.conversationView(channelId)?.updateReactions(messageId, reactions)
        }
        discord.onVoiceChange = { [weak self] in
            (self?.desktop.windows.first { $0.content is ChatRoomsView }?.content as? ChatRoomsView)?.reloadRooms()
        }
        discord.onMention = { [weak self] server, room, message in self?.receiveMention(message, in: room, on: server) }
        discord.onRoomActivity = { [weak self] server, room, message in self?.receiveRoomActivity(message, in: room, on: server) }
        DiscordSync.start(self)
        discord.onReady = { [weak self] in
            guard let self else { return }
            for (id, window) in self.imWindows
            where ChatServiceKind(id: id) == .discord && (window.content as? InstantMessageView)?.tracksSpeakers == true {
                self.discord.watch(id, true)
            }
        }
    }

    var hiddenBuddyIDs: Set<String> { Set(config.hiddenBuddies) }

    /// The service whose web app runs the Discord bridge. The default config calls it `chat`.
    var discordServiceID: String? {
        config.services.first { DiscordBridge.isDiscordHost(URL(string: $0.url)?.host) }?.id
    }

    func ensureDiscordPane() {
        guard !discord.hasPane, let id = discordServiceID else { return }
        openService(id, minimized: true)
    }

    func openBuddyList(minimized: Bool = false) {
        guard signedOn else { return }
        ensureDiscordPane()
        ensureMessengerPane()
        if let w = buddyListWindow, w.superview != nil {
            if !minimized { desktop.activate(w) }
            return
        }
        let view = BuddyListView()
        view.onOpen = { [weak self] buddy in self?.openIM(with: buddy) }
        view.onOpenChat = { [weak self] chat in self?.openGroupChat(chat) }
        view.onInfo = { [weak self] buddy in self?.showInApp(buddy) }
        view.onHide = { [weak self] buddy in
            self?.updateConfig { if !$0.hiddenBuddies.contains(buddy.id) { $0.hiddenBuddies.append(buddy.id) } }
            self?.refreshBuddies()
        }
        view.onUnhide = { [weak self] id in
            self?.updateConfig { $0.hiddenBuddies.removeAll { $0 == id } }
            self?.refreshBuddies()
        }
        view.onConnect = { [weak self] in
            guard let self else { return }
            if !self.messenger.isReady, let id = self.messengerServiceID { self.openService(id) }
            if !self.discord.isReady, let id = self.discordServiceID { self.openService(id) }
        }
        let window = MDIWindow(title: "Buddy List", icon: Icons.symbol("person.2.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 200, height: 300)
        window.focusView = view.tree
        window.onClose = { [weak self] in
            self?.buddyListWindow = nil
            self?.buddyListView = nil
        }
        buddyListWindow = window
        buddyListView = view
        let width: CGFloat = 240
        let height = min(desktop.bounds.height - 20, 640)
        desktop.add(window, size: NSSize(width: width, height: height), minimized: minimized)
        window.setMaximizedFrame(NSRect(x: max(0, desktop.bounds.width - width - 10), y: 10, width: width, height: height))
        view.reload(discord, slack: slack, messenger: messenger, hidden: hiddenBuddyIDs)
    }

    func refreshBuddies() {
        buddyListView?.reload(discord, slack: slack, messenger: messenger, hidden: hiddenBuddyIDs)
        for (id, window) in imWindows {
            guard let view = window.content as? InstantMessageView else { continue }
            if view.isGroup, let chat = chatService(for: id).group(id) {
                view.members = chat.members
                window.title = "\(chat.name) - Chat"
            } else if !view.isGroup, let buddy = chatService(for: id).buddy(id) {
                view.update(buddy: buddy)
                window.title = "\(buddy.name) - Instant Message"
            }
        }
    }

    @discardableResult
    func openGroupChat(_ chat: GroupChat) -> InstantMessageView? {
        let service = chatService(for: chat.id)
        guard signedOn, let myID = service.myID else { return nil }
        if let w = imWindows[chat.id], w.superview != nil, let view = w.content as? InstantMessageView {
            desktop.activate(w)
            return view
        }
        let stub = Buddy(id: chat.id, name: chat.name, presence: .online)
        let view = InstantMessageView(buddy: stub, myID: myID, myName: service.myName, isGroup: true)
        view.members = chat.members
        let window = MDIWindow(title: "\(chat.name) - Chat", icon: Icons.symbol("person.3.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 460, height: 340)
        openConversation(view, in: window, target: .channel(chat.id), size: NSSize(width: 640, height: 460))
        return view
    }

    @discardableResult
    func openIM(with buddy: Buddy) -> InstantMessageView? {
        let service = chatService(for: buddy.id)
        guard signedOn, let myID = service.myID else { return nil }
        if let w = imWindows[buddy.id], w.superview != nil, let view = w.content as? InstantMessageView {
            desktop.activate(w)
            return view
        }
        let view = InstantMessageView(buddy: buddy, myID: myID, myName: service.myName)
        let window = MDIWindow(title: "\(buddy.name) - Instant Message",
                               icon: Icons.symbol("message.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 360, height: 320)
        view.onInfo = { [weak self] in self?.showInApp(buddy) }
        openConversation(view, in: window, target: .user(buddy.id), size: NSSize(width: 500, height: 440))
        return view
    }

    /// The open IM, group chat or room window showing a Discord channel.
    func conversationView(_ channelId: String) -> InstantMessageView? {
        if let view = imWindows[channelId]?.content as? InstantMessageView { return view }
        return imWindows.values.lazy.compactMap { $0.content as? InstantMessageView }.first { $0.channelID == channelId }
    }

    /// Fetches the newest messages for every open conversation and adds any that live events missed.
    func syncConversations() {
        for window in imWindows.values {
            guard let view = window.content as? InstantMessageView, let target = view.target else { continue }
            let service = chatService(for: target.id)
            guard service.isReady else { continue }
            if SlackID.owns(target.id), !slack.resyncDue(target.id) { continue }
            service.latest(in: target, limit: 20) { [weak self, weak view, weak window, weak service] result in
                guard let self, let view, case .success(let messages) = result else { return }
                var added = false
                for message in messages {
                    if view.append(message) {
                        added = added || message.authorID != service?.myID
                    } else {
                        view.updateReactions(message.id, message.reactions)
                    }
                }
                if added, let window, !window.isActive {
                    window.attention = true
                    self.desktop.windowsChanged()
                }
            }
        }
    }

    private func openConversation(_ view: InstantMessageView, in window: MDIWindow, target: ChatTarget, size: NSSize) {
        view.target = target
        view.onMessagePerson = { [weak self] id, name in
            guard let self else { return }
            self.openIM(with: self.chatService(for: id).buddy(id) ?? Buddy(id: id, name: name, presence: .online))
        }
        window.focusView = view.input
        window.minimizesToSide = true
        window.onClose = { [weak self] in self?.imWindows[target.id] = nil }
        imWindows[target.id] = window
        view.onOpenLink = { [weak self] url in self?.openBrowser(url) }
        view.onSend = { [weak self, weak view] text, files, replyTo in
            guard let self, let view else { return }
            view.setBusy(true)
            self.chatService(for: target.id).send(text, files: files, to: target, replyTo: replyTo) { [weak view] error in
                view?.setBusy(false)
                if let error {
                    view?.appendNotice("Message not sent: \(error.localizedDescription)")
                    view?.restoreUnsent()
                    NSSound.beep()
                } else {
                    view?.didSend()
                    SoundManager.shared.play(.imSend)
                }
            }
        }
        desktop.add(window, size: size)

        // History comes from the service's API so a channel the Discord client never loaded is current. The Discord
        // client's own store is the fallback.
        view.beginHistory()
        chatService(for: target.id).latest(in: target, limit: 30) { [weak self, weak view] result in
            guard let view else { return }
            if case .success(let messages) = result {
                view.finishHistory(messages)
                return
            }
            if case .failure(let error) = result, ChatServiceKind(id: target.id) != .discord {
                view.finishHistory([])
                view.appendNotice(error.localizedDescription)
                return
            }
            self?.discord.history(with: target) { [weak view] result in
                switch result {
                case .success(let messages):
                    view?.finishHistory(messages)
                case .failure(let error):
                    view?.finishHistory([])
                    view?.appendNotice(error.localizedDescription)
                }
            }
        }
    }

    func openChatRooms() {
        guard signedOn else { return }
        ensureDiscordPane()
        if let w = desktop.windows.first(where: { $0.content is ChatRoomsView }) {
            desktop.activate(w)
            return
        }
        let view = ChatRoomsView()
        let window = MDIWindow(title: "People Connection - Find a Chat",
                               icon: Icons.symbol("bubble.left.and.bubble.right.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 480, height: 360)
        window.focusView = view.serverList
        view.onPickServer = { [weak self, weak view] server in
            self?.chatService(for: server.id).rooms(in: server.id) { result in
                switch result {
                case .success(let rooms): view?.showRooms(rooms)
                case .failure(let error): view?.showRooms([], error: error.localizedDescription)
                }
            }
        }
        view.onEnter = { [weak self] server, room in
            if room.voice {
                self?.discord.joinVoice(room.id)
            } else {
                self?.openChatRoom(room, in: server)
            }
        }
        view.onLeaveVoice = { [weak self] in self?.discord.joinVoice(nil) }
        view.favoriteRoomIDs = config.favoriteRooms.map(\.id)
        view.onToggleFavorite = { [weak self] server, room in self?.toggleFavoriteRoom(room, in: server) }
        view.mutedIDs = config.mutedRooms
        view.onToggleMute = { [weak self] id in self?.toggleMute(id) }
        view.onRefresh = { [weak self, weak view] in self?.loadServers(into: view) }
        desktop.add(window, size: NSSize(width: 640, height: 480), centered: true)
        loadServers(into: view)
    }

    /// The Slack workspace is listed first, then Discord servers.
    private func loadServers(into view: ChatRoomsView?) {
        let workspaces = slack.workspace.map { [$0] } ?? []
        discord.servers { [weak view] result in
            switch result {
            case .success(let servers):
                view?.showServers(workspaces + servers)
                view?.setStatus(ChatRoomCount.status(workspaces: workspaces.count, servers: servers.count))
            case .failure(let error):
                view?.showServers(workspaces)
                view?.setStatus(workspaces.isEmpty ? error.localizedDescription
                                                   : ChatRoomCount.status(workspaces: workspaces.count, servers: 0))
            }
        }
    }

    func openChatRoom(_ room: ChatRoom, in server: ChatServer) {
        openChatRoom(id: room.id, name: room.name, serverName: server.name)
    }

    /// Adds the room to People > Favorites, or removes it when it is already there.
    func toggleFavoriteRoom(_ room: ChatRoom, in server: ChatServer) {
        updateConfig {
            if $0.favoriteRooms.contains(where: { $0.id == room.id }) {
                $0.favoriteRooms.removeAll { $0.id == room.id }
            } else {
                $0.favoriteRooms.append(FavoriteRoom(id: room.id, name: room.name, serverID: server.id,
                                                     serverName: server.name, voice: room.voice))
            }
        }
        let ids = config.favoriteRooms.map(\.id)
        for case let view as ChatRoomsView in desktop.windows.map(\.content) { view.favoriteRoomIDs = ids }
    }

    func openFavoriteRoom(_ room: FavoriteRoom) {
        guard signedOn else { return }
        ensureDiscordPane()
        if room.voice {
            discord.joinVoice(room.id)
        } else {
            openChatRoom(id: room.id, name: room.name, serverName: room.serverName)
        }
    }

    /// The People > Favorites submenu: "{Server Name} - #{Channel}" for each favorite room.
    func favoriteRoomsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        item.image = Icons.symbol("heart.fill", size: 13, colors: [Theme.aolBlue])
        let submenu = NSMenu()
        for room in config.favoriteRooms {
            let entry = ActionItem(room.voice ? "\(room.serverName) - \u{1F50A} \(room.name)" : room.title) { [weak self] in
                self?.openFavoriteRoom(room)
            }
            submenu.addItem(entry)
        }
        if config.favoriteRooms.isEmpty {
            let empty = NSMenuItem(title: "Right click a room in Chat Rooms to add it", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        item.submenu = submenu
        return item
    }

    func openChatRoom(id: String, name: String, serverName: String) {
        let service = chatService(for: id)
        guard signedOn, let myID = service.myID else { return }
        if let w = imWindows[id], w.superview != nil {
            desktop.activate(w)
            return
        }
        let stub = Buddy(id: id, name: "#\(name)", presence: .online)
        let view = InstantMessageView(buddy: stub, myID: myID, myName: service.myName, isGroup: true)
        view.tracksSpeakers = true
        let window = MDIWindow(title: "#\(name) - \(serverName)",
                               icon: Icons.symbol("bubble.left.and.bubble.right.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 460, height: 340)
        openConversation(view, in: window, target: .channel(id), size: NSSize(width: 700, height: 500))
        service.watch(id, true)
        let close = window.onClose
        window.onClose = { [weak service] in
            close?()
            service?.watch(id, false)
        }
    }

    /// A mention opens the room like an incoming IM, with imrcv and a status line.
    func receiveMention(_ message: DirectMessage, in room: ChatRoom, on server: ChatServer) {
        SoundManager.shared.play(.imReceive)
        let who = message.authorName.isEmpty ? "Someone" : message.authorName
        shell.statusBar.status = "\(who) mentioned you in #\(room.name)" + (server.name.isEmpty ? "" : " on \(server.name)")
        if let w = imWindows[room.id], let view = w.content as? InstantMessageView {
            view.append(message)
            if !w.isActive {
                w.attention = true
                desktop.windowsChanged()
            }
            return
        }
        openChatRoom(room, in: server)
        (imWindows[room.id]?.content as? InstantMessageView)?.append(message)
    }

    /// A message in a room with no open window opens the room, unless the room, its category or its server is muted.
    func receiveRoomActivity(_ message: DirectMessage, in room: ChatRoom, on server: ChatServer) {
        guard imWindows[room.id]?.superview == nil, message.authorID != chatService(for: room.id).myID,
              !ChatMute.isMuted(room, in: server, muted: config.mutedRooms) else { return }
        SoundManager.shared.play(.imReceive)
        openChatRoom(room, in: server)
        (imWindows[room.id]?.content as? InstantMessageView)?.append(message)
    }

    /// Mutes a server, category or room, or unmutes it when it is already muted.
    func toggleMute(_ id: String) {
        updateConfig {
            if $0.mutedRooms.contains(id) { $0.mutedRooms.removeAll { $0 == id } } else { $0.mutedRooms.append(id) }
        }
        for case let view as ChatRoomsView in desktop.windows.map(\.content) { view.mutedIDs = config.mutedRooms }
    }

    func receiveRoomMessage(_ channelId: String, _ message: DirectMessage) {
        guard let w = imWindows[channelId], let view = w.content as? InstantMessageView, view.append(message) else { return }
        if !w.isActive, message.authorID != chatService(for: channelId).myID {
            w.attention = true
            desktop.windowsChanged()
        }
    }

    func receiveGroupMessage(_ chat: GroupChat, _ message: DirectMessage) {
        refreshBuddies()
        let mine = message.authorID == chatService(for: chat.id).myID
        if let w = imWindows[chat.id], let view = w.content as? InstantMessageView {
            guard view.append(message), !mine else { return }
            SoundManager.shared.play(.imReceive)
            if !w.isActive {
                w.attention = true
                desktop.windowsChanged()
            }
            return
        }
        guard !mine else { return }
        SoundManager.shared.play(.imReceive)
        openGroupChat(chat)?.append(message)
    }

    func receiveIM(from userId: String, _ message: DirectMessage) {
        let service = chatService(for: userId)
        let mine = message.authorID == service.myID
        if let w = imWindows[userId], let view = w.content as? InstantMessageView {
            guard view.append(message), !mine else { return }
            SoundManager.shared.play(.imReceive)
            if !w.isActive {
                w.attention = true
                desktop.windowsChanged()
            }
            return
        }
        guard !mine else { return }
        let buddy = service.buddy(userId) ?? Buddy(id: userId, name: message.authorName.isEmpty ? userId : message.authorName,
                                                   presence: .online)
        SoundManager.shared.play(.imReceive)
        guard let view = openIM(with: buddy) else { return }
        view.append(message)
    }

    private func showInApp(_ buddy: Buddy) {
        chatService(for: buddy.id).openInApp(buddy.id)
        switch ChatServiceKind(id: buddy.id) {
        case .discord: if let id = discordServiceID { openService(id) }
        case .messenger: if let id = messengerServiceID { openService(id) }
        case .slack: break
        }
    }

    func closeDiscordWindows() {
        imWindows.removeAll()
        buddyListWindow = nil
        buddyListView = nil
        discord.reset()
        messenger.reset()
        slack.stop()
    }
}
