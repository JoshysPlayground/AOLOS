import AppKit

extension Session {
    func setUpDiscord() {
        discord.onChange = { [weak self] in self?.refreshBuddies() }
        discord.onBuddyChange = { [weak self] buddy, change in
            guard let self, !self.hiddenBuddyIDs.contains(buddy.id) else { return }
            SoundManager.shared.play(change.sound)
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
        DiscordSync.start(self)
        discord.onReady = { [weak self] in
            guard let self else { return }
            for (id, window) in self.imWindows where (window.content as? InstantMessageView)?.tracksSpeakers == true {
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
        if let w = buddyListWindow, w.superview != nil {
            if !minimized { desktop.activate(w) }
            return
        }
        let view = BuddyListView()
        view.onOpen = { [weak self] buddy in self?.openIM(with: buddy) }
        view.onOpenChat = { [weak self] chat in self?.openGroupChat(chat) }
        view.onInfo = { [weak self] buddy in self?.showInDiscord(buddy) }
        view.onHide = { [weak self] buddy in
            self?.updateConfig { if !$0.hiddenBuddies.contains(buddy.id) { $0.hiddenBuddies.append(buddy.id) } }
            self?.refreshBuddies()
        }
        view.onUnhide = { [weak self] id in
            self?.updateConfig { $0.hiddenBuddies.removeAll { $0 == id } }
            self?.refreshBuddies()
        }
        view.onConnect = { [weak self] in
            guard let self, let id = self.discordServiceID else { return }
            self.openService(id)
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
        view.reload(discord, hidden: hiddenBuddyIDs)
    }

    func refreshBuddies() {
        buddyListView?.reload(discord, hidden: hiddenBuddyIDs)
        for (id, window) in imWindows {
            guard let view = window.content as? InstantMessageView else { continue }
            if view.isGroup, let chat = discord.group(id) {
                view.members = chat.members
                window.title = "\(chat.name) - Chat"
            } else if !view.isGroup, let buddy = discord.buddy(id) {
                view.update(buddy: buddy)
                window.title = "\(buddy.name) - Instant Message"
            }
        }
    }

    @discardableResult
    func openGroupChat(_ chat: GroupChat) -> InstantMessageView? {
        guard signedOn, let me = discord.me else { return nil }
        if let w = imWindows[chat.id], w.superview != nil, let view = w.content as? InstantMessageView {
            desktop.activate(w)
            return view
        }
        let stub = Buddy(id: chat.id, name: chat.name, presence: .online)
        let view = InstantMessageView(buddy: stub, myID: me.id, myName: me.name, isGroup: true)
        view.members = chat.members
        let window = MDIWindow(title: "\(chat.name) - Chat", icon: Icons.symbol("person.3.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 460, height: 340)
        openConversation(view, in: window, target: .channel(chat.id), size: NSSize(width: 640, height: 460))
        return view
    }

    @discardableResult
    func openIM(with buddy: Buddy) -> InstantMessageView? {
        guard signedOn, let me = discord.me else { return nil }
        if let w = imWindows[buddy.id], w.superview != nil, let view = w.content as? InstantMessageView {
            desktop.activate(w)
            return view
        }
        let view = InstantMessageView(buddy: buddy, myID: me.id, myName: me.name)
        let window = MDIWindow(title: "\(buddy.name) - Instant Message",
                               icon: Icons.symbol("message.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 360, height: 320)
        view.onInfo = { [weak self] in self?.showInDiscord(buddy) }
        openConversation(view, in: window, target: .user(buddy.id), size: NSSize(width: 500, height: 440))
        return view
    }

    /// Shared setup for IM and group chat windows: sending, history and bookkeeping.
    /// The open IM, group chat or room window showing a Discord channel.
    func conversationView(_ channelId: String) -> InstantMessageView? {
        if let view = imWindows[channelId]?.content as? InstantMessageView { return view }
        return imWindows.values.lazy.compactMap { $0.content as? InstantMessageView }.first { $0.channelID == channelId }
    }

    /// Fetches the newest messages for every open conversation and adds any that live events missed.
    func syncConversations() {
        guard discord.state == .ready else { return }
        for window in imWindows.values {
            guard let view = window.content as? InstantMessageView, let target = view.target else { continue }
            discord.latest(in: target) { [weak self, weak view, weak window] result in
                guard let self, let view, case .success(let messages) = result else { return }
                var added = false
                for message in messages {
                    if view.append(message) {
                        added = added || message.authorID != self.discord.me?.id
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
            self.openIM(with: self.discord.buddy(id) ?? Buddy(id: id, name: name, presence: .online))
        }
        window.focusView = view.input
        window.onClose = { [weak self] in self?.imWindows[target.id] = nil }
        imWindows[target.id] = window
        view.onOpenLink = { [weak self] url in self?.openBrowser(url) }
        view.onSend = { [weak self, weak view] text, files, replyTo in
            guard let self, let view else { return }
            view.setBusy(true)
            self.discord.send(text, files: files, to: target, replyTo: replyTo) { [weak view] error in
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

        // History comes from Discord's API so a channel the client never loaded is current. The client's own store
        // is the fallback.
        view.beginHistory()
        discord.latest(in: target, limit: 30) { [weak self, weak view] result in
            guard let view else { return }
            if case .success(let messages) = result {
                view.finishHistory(messages)
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
            self?.discord.rooms(in: server.id) { result in
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
        view.onRefresh = { [weak self, weak view] in self?.loadServers(into: view) }
        desktop.add(window, size: NSSize(width: 640, height: 480), centered: true)
        loadServers(into: view)
    }

    private func loadServers(into view: ChatRoomsView?) {
        discord.servers { [weak view] result in
            switch result {
            case .success(let servers):
                view?.showServers(servers)
                view?.setStatus("\(servers.count) servers")
            case .failure(let error):
                view?.setStatus(error.localizedDescription)
            }
        }
    }

    func openChatRoom(_ room: ChatRoom, in server: ChatServer) {
        guard signedOn, let me = discord.me else { return }
        if let w = imWindows[room.id], w.superview != nil {
            desktop.activate(w)
            return
        }
        let stub = Buddy(id: room.id, name: "#\(room.name)", presence: .online)
        let view = InstantMessageView(buddy: stub, myID: me.id, myName: me.name, isGroup: true)
        view.tracksSpeakers = true
        let window = MDIWindow(title: "#\(room.name) - \(server.name)",
                               icon: Icons.symbol("bubble.left.and.bubble.right.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 460, height: 340)
        openConversation(view, in: window, target: .channel(room.id), size: NSSize(width: 700, height: 500))
        discord.watch(room.id, true)
        let close = window.onClose
        window.onClose = { [weak self] in
            close?()
            self?.discord.watch(room.id, false)
        }
    }

    /// A mention opens the room like an incoming IM, with imrcv and a status line.
    private func receiveMention(_ message: DirectMessage, in room: ChatRoom, on server: ChatServer) {
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

    private func receiveRoomMessage(_ channelId: String, _ message: DirectMessage) {
        guard let w = imWindows[channelId], let view = w.content as? InstantMessageView, view.append(message) else { return }
        if !w.isActive, message.authorID != discord.me?.id {
            w.attention = true
            desktop.windowsChanged()
        }
    }

    private func receiveGroupMessage(_ chat: GroupChat, _ message: DirectMessage) {
        refreshBuddies()
        let mine = message.authorID == discord.me?.id
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

    private func receiveIM(from userId: String, _ message: DirectMessage) {
        let mine = message.authorID == discord.me?.id
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
        let buddy = discord.buddy(userId) ?? Buddy(id: userId, name: userId, presence: .online)
        SoundManager.shared.play(.imReceive)
        guard let view = openIM(with: buddy) else { return }
        view.append(message)
    }

    private func showInDiscord(_ buddy: Buddy) {
        discord.openInDiscord(buddy.id)
        if let id = discordServiceID { openService(id) }
    }

    func closeDiscordWindows() {
        imWindows.removeAll()
        buddyListWindow = nil
        buddyListView = nil
        discord.reset()
    }
}
