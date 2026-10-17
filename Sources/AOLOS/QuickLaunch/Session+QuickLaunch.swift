import AppKit

/// Quick Launch (Cmd+T): one box in the middle of the AOL window that searches Google, opens a web address,
/// enters a chat room or starts an IM, across Discord, Slack and Messenger.
extension Session {
    var quickLaunch: QuickLaunchOverlay? { shell.subviews.lazy.compactMap { $0 as? QuickLaunchOverlay }.first }

    func toggleQuickLaunch() {
        if let open = quickLaunch { open.dismiss() } else { showQuickLaunch() }
    }

    func showQuickLaunch() {
        guard signedOn, NSApp.modalWindow == nil else { NSSound.beep(); return }
        if let open = quickLaunch { open.panel.focus(); return }
        let overlay = QuickLaunchOverlay(frame: shell.bounds)
        let panel = overlay.panel
        panel.urlFor = { Session.webURL(from: $0) }
        panel.sources = quickLaunchSources()
        panel.onPick = { [weak self] item in self?.performQuickLaunch(item) }
        panel.onQuery = { [weak self, weak panel] query in
            guard let self, self.discord.isReady else { return }
            self.discord.searchPeople(query) { people in panel?.sources.add(people: people) }
        }
        shell.addSubview(overlay)
        overlay.present()

        // Discord rooms come from the page, so they fill in a moment after the box opens.
        if discord.isReady {
            discord.allRooms { [weak panel] result in
                if case .success(let rooms) = result { panel?.sources.add(rooms: rooms) }
            }
        }
    }

    /// People and rooms from every signed on service, most likely first.
    func quickLaunchSources() -> QuickLaunchSources {
        var sources = QuickLaunchSources()
        let services: [(any ChatService, recent: [Buddy], buddies: [Buddy])] = [
            (discord, discord.recentBuddies, discord.sortedBuddies),
            (slack, slack.recentBuddies, slack.buddies),
            (messenger, messenger.recentBuddies, messenger.sortedBuddies),
        ].filter { $0.0.isReady }
        let recent = services.map(\.recent).reduce([]) { RecentBuddies.interleave($0, $1) }
        sources.add(people: recent)
        services.forEach { sources.add(people: $0.buddies) }
        if slack.isReady { sources.add(people: slack.people) }

        sources.favoriteRoomIDs = Set(config.favoriteRooms.map(\.id))
        sources.add(rooms: config.favoriteRooms.map(QuickRoom.init))
        if slack.isReady {
            let workspace = slack.team?.name ?? "Slack"
            sources.add(rooms: slack.roomList.map { QuickRoom(id: $0.id, name: $0.name, serverName: workspace) })
        }

        let builtIn = ["buddy list", "chat rooms", "favorites", "radio", "gmail", "settings", "welcome"]
        sources.keywords = Array(Set(builtIn + config.keywords.keys + config.services.map(\.id))).sorted()
        return sources
    }

    func performQuickLaunch(_ item: QuickLaunchItem) {
        switch item.action {
        case .website(let url):
            openBrowser(url)
        case .search(let query):
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            if let url = c.url { openBrowser(url) }
        case .person(let buddy):
            if ChatServiceKind(id: buddy.id) == .discord { discord.remember(buddy) }
            if openIM(with: buddy) == nil { NSSound.beep() }
        case .room(let room):
            if ChatServiceKind(id: room.id) == .discord { ensureDiscordPane() }
            if room.voice {
                discord.joinVoice(room.id)
            } else {
                openChatRoom(id: room.id, name: room.name, serverName: room.serverName)
            }
        case .keyword(let keyword):
            go(keyword)
        }
    }
}
