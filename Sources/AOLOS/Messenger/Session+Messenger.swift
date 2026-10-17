import AppKit

extension Session {
    func setUpMessenger() {
        messenger.onChange = { [weak self] in self?.refreshBuddies() }
        messenger.onBuddyChange = { [weak self] buddy, change in
            guard let self, !self.hiddenBuddyIDs.contains(buddy.id) else { return }
            self.shell.statusBar.status = "\(buddy.name) \(change.verb)."
        }
        messenger.onMessage = { [weak self] userId, message in self?.receiveIM(from: userId, message) }
        messenger.onGroupMessage = { [weak self] chat, message in self?.receiveGroupMessage(chat, message) }
    }

    /// The service whose web app runs the Messenger bridge. The default config calls it `messenger`.
    var messengerServiceID: String? {
        config.services.first { MessengerBridge.isMessengerService($0.url) }?.id
    }

    func ensureMessengerPane() {
        guard !messenger.hasPane, let id = messengerServiceID else { return }
        openService(id, minimized: true)
    }
}

extension MessengerBridge: ChatService {
    var isReady: Bool { state == .ready }
    var myID: String? { me?.id }
    var myName: String { me?.name ?? "" }

    func rooms(in serverId: String, completion: @escaping @MainActor (Result<[ChatRoom], Error>) -> Void) {
        completion(.success([]))
    }

    func watch(_ channelId: String, _ on: Bool) {}

    func openInApp(_ userId: String) { open(.user(userId)) }
}
