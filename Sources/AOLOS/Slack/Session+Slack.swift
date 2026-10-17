import AppKit

extension Session {
    func setUpSlack() {
        slack.onChange = { [weak self] in
            self?.refreshBuddies()
            self?.settingsView?.refreshSlackStatus()
        }
        slack.onBuddyChange = { [weak self] buddy, change in
            guard let self, !self.hiddenBuddyIDs.contains(buddy.id) else { return }
            self.shell.statusBar.status = "\(buddy.name) \(change.verb)."
        }
        slack.onMessage = { [weak self] userId, message in self?.receiveIM(from: userId, message) }
        slack.onGroupMessage = { [weak self] chat, message in self?.receiveGroupMessage(chat, message) }
        slack.onRoomMessage = { [weak self] channelId, message in self?.receiveRoomMessage(channelId, message) }
        slack.onReactions = { [weak self] channelId, messageId, reactions in
            self?.conversationView(channelId)?.updateReactions(messageId, reactions)
        }
        slack.onMention = { [weak self] server, room, message in self?.receiveMention(message, in: room, on: server) }
        slack.onRoomActivity = { [weak self] server, room, message in self?.receiveRoomActivity(message, in: room, on: server) }
    }

    /// The service that owns a buddy, group chat, room or workspace ID.
    func chatService(for id: String) -> ChatService {
        switch ChatServiceKind(id: id) {
        case .slack: return slack
        case .messenger: return messenger
        case .discord: return discord
        }
    }

    func connectSlack(userToken: String?, appToken: String?) {
        SlackClient.saveTokens(user: userToken, app: appToken)
        slack.stop()
        slack.start()
        settingsView?.refreshSlackStatus()
    }

    func disconnectSlack() {
        slack.stop()
        SlackClient.saveTokens(user: "", app: "")
        settingsView?.refreshSlackStatus()
    }
}
