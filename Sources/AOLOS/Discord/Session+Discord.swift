import AppKit

extension Session {
    func setUpDiscord() {
        discord.onChange = { [weak self] in self?.refreshBuddies() }
        discord.onBuddyChange = { [weak self] buddy, change in
            SoundManager.shared.play(change.sound)
            self?.shell.statusBar.status = "\(buddy.name) \(change.verb)."
        }
        discord.onMessage = { [weak self] userId, message in self?.receiveIM(from: userId, message) }
    }

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
        view.onInfo = { [weak self] buddy in self?.showInDiscord(buddy) }
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
        view.reload(discord)
    }

    func refreshBuddies() {
        buddyListView?.reload(discord)
        for (id, window) in imWindows {
            guard let view = window.content as? InstantMessageView, let buddy = discord.buddies[id] else { continue }
            view.update(buddy: buddy)
            window.title = "\(buddy.name) - Instant Message"
        }
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
        window.focusView = view.input
        window.onClose = { [weak self] in self?.imWindows[buddy.id] = nil }
        imWindows[buddy.id] = window
        view.onInfo = { [weak self] in self?.showInDiscord(buddy) }
        view.onSend = { [weak self, weak view] text in
            guard let self, let view else { return }
            view.setBusy(true)
            self.discord.send(text, to: buddy.id) { [weak view] error in
                view?.setBusy(false)
                if let error {
                    view?.appendNotice("Message not sent: \(error.localizedDescription)")
                    NSSound.beep()
                } else {
                    view?.didSend()
                    SoundManager.shared.play(.imSend)
                }
            }
        }
        desktop.add(window, size: NSSize(width: 500, height: 440))

        discord.history(with: buddy.id) { [weak view] result in
            guard let view else { return }
            switch result {
            case .success(let messages):
                messages.sorted { $0.date < $1.date }.forEach { view.append($0) }
            case .failure(let error):
                view.appendNotice(error.localizedDescription)
            }
        }
        return view
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
        let buddy = discord.buddies[userId] ?? Buddy(id: userId, name: userId, presence: .online)
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
