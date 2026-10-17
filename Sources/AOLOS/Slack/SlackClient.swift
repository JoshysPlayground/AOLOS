import AppKit

/// Slack through the official Web API and Socket Mode. Direct message partners are buddies, group DMs are group
/// chats, and the workspace's channels are chat rooms. Every ID it hands out carries the `slack:` prefix.
@MainActor
final class SlackClient {
    enum State: Equatable {
        case off
        case connecting
        case ready
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var me: (id: String, name: String, avatar: URL?)?
    private(set) var team: (id: String, name: String, icon: URL?)?
    private(set) var recentBuddies: [Buddy] = []
    private(set) var recent: [String: (change: BuddyChange, date: Date)] = [:]
    var isLive: Bool { socket?.isConnected == true }

    var onChange: (() -> Void)?
    var onBuddyChange: ((Buddy, BuddyChange) -> Void)?
    var onMessage: ((String, DirectMessage) -> Void)?
    var onGroupMessage: ((GroupChat, DirectMessage) -> Void)?
    var onRoomMessage: ((String, DirectMessage) -> Void)?
    var onReactions: ((String, String, [MessageReaction]) -> Void)?
    var onMention: ((ChatServer, ChatRoom, DirectMessage) -> Void)?
    var onRoomActivity: ((ChatServer, ChatRoom, DirectMessage) -> Void)?
    var onReady: (() -> Void)?

    private var api: SlackAPI?
    private var socket: SlackSocket?
    private var users: [String: SlackUser] = [:]
    private var userByHandle: [String: String] = [:]
    /// Direct message channel to partner, and partner to channel. Raw Slack IDs.
    private var imUser: [String: String] = [:]
    private var imChannel: [String: String] = [:]
    /// Partners shown under Buddies, in Slack's own priority order.
    private var buddyIDs: [String] = []
    private var groupChannels: [String: [String: Any]] = [:]
    private var groupOrder: [String] = []
    private var rooms: [String: ChatRoom] = [:]
    private var roomOrder: [String] = []
    private var presence: [String: Buddy.Presence] = [:]
    /// Thread roots by message timestamp, so replying to a reply lands in the same thread.
    private var threadRoot: [String: String] = [:]
    private var pollTimer: Timer?
    private var pollIndex = 0
    private var lastResync: [String: Date] = [:]
    private var generation = 0

    static let maxBuddies = 60
    static let pollInterval: TimeInterval = 3
    static let resyncInterval: TimeInterval = 60
    static let recentInterval: TimeInterval = 8

    static let userTokenKey = "slack.userToken"
    static let appTokenKey = "slack.appToken"
    static var userToken: String? { Keychain.secret(userTokenKey).flatMap { $0.isEmpty ? nil : $0 } }
    static var appToken: String? { Keychain.secret(appTokenKey).flatMap { $0.isEmpty ? nil : $0 } }
    static var isConfigured: Bool { userToken != nil }

    static func saveTokens(user: String?, app: String?) {
        if let user { Keychain.setSecret(userTokenKey, user.isEmpty ? nil : user) }
        if let app { Keychain.setSecret(appTokenKey, app.isEmpty ? nil : app) }
    }

    // MARK: Lifecycle

    func start() {
        guard let token = Self.userToken else { return }
        switch state {
        case .connecting, .ready: return
        default: break
        }
        state = .connecting
        onChange?()
        generation += 1
        let gen = generation
        Task { await connect(token, gen) }
    }

    func stop() {
        generation += 1
        socket?.stop()
        socket = nil
        pollTimer?.invalidate()
        pollTimer = nil
        api = nil
        MediaAuth.slackToken = nil
        state = .off
        me = nil
        team = nil
        users = [:]
        userByHandle = [:]
        imUser = [:]
        imChannel = [:]
        buddyIDs = []
        groupChannels = [:]
        groupOrder = []
        rooms = [:]
        roomOrder = []
        presence = [:]
        recent = [:]
        recentBuddies = []
        threadRoot = [:]
        lastResync = [:]
        onChange?()
    }

    private func connect(_ token: String, _ gen: Int) async {
        let api = SlackAPI(token: token)
        do {
            let auth = try await api.call("auth.test")
            guard let userID = auth["user_id"] as? String, let teamID = auth["team_id"] as? String else {
                throw SlackAPIError(code: "bad_response")
            }
            let members = try await api.paged("users.list", key: "members")
            let info = try? await api.call("team.info")
            let conversations = try await api.paged("users.conversations",
                                                    ["types": "im,mpim,public_channel,private_channel", "exclude_archived": true],
                                                    key: "channels")
            guard gen == generation else { return }
            self.api = api
            MediaAuth.slackToken = token
            for json in members {
                guard let user = SlackUser(json: json) else { continue }
                users[user.id] = user
                userByHandle[user.handle] = user.id
            }
            let teamJSON = info?["team"] as? [String: Any]
            let icon = (teamJSON?["icon"] as? [String: Any])?["image_68"] as? String
            team = (teamID, teamJSON?["name"] as? String ?? auth["team"] as? String ?? "Slack", icon.flatMap(URL.init(string:)))
            let mine = users[userID]
            me = (SlackID.wrap(userID), mine?.name ?? auth["user"] as? String ?? userID, mine?.avatarURL)
            apply(conversations)
            state = .ready
            onChange?()
            onReady?()
            startPresencePolling()
            startSocket()
        } catch {
            guard gen == generation else { return }
            NSLog("AOL-OS: Slack sign on failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            onChange?()
        }
    }

    private func apply(_ conversations: [[String: Any]]) {
        var partners: [(String, Double)] = []
        groupChannels = [:]
        groupOrder = []
        rooms = [:]
        for json in conversations {
            guard let id = json["id"] as? String else { continue }
            if json["is_im"] as? Bool == true {
                guard let user = json["user"] as? String, user != rawMe, users[user]?.isPerson ?? true,
                      json["is_user_deleted"] as? Bool != true else { continue }
                imUser[id] = user
                imChannel[user] = id
                partners.append((user, (json["priority"] as? NSNumber)?.doubleValue ?? 0))
            } else if json["is_mpim"] as? Bool == true {
                groupChannels[id] = json
                groupOrder.append(id)
            } else if let room = ChatRoom(json: [
                "id": SlackID.wrap(id), "name": json["name"] as? String ?? id,
                "category": json["is_private"] as? Bool == true ? "Private Channels" : "Channels",
                "categoryId": SlackID.wrap(json["is_private"] as? Bool == true ? "private-channels" : "channels"),
            ]) {
                rooms[id] = room
            }
        }
        let ranked = partners.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : (users[$0.0]?.name ?? "") < (users[$1.0]?.name ?? "") }
        buddyIDs = Array(ranked.map(\.0).prefix(Self.maxBuddies))
        roomOrder = rooms.keys.sorted {
            let a = rooms[$0]!, b = rooms[$1]!
            if a.category != b.category { return a.category < b.category }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var rawMe: String { me.map { SlackID.raw($0.id) } ?? "" }

    // MARK: Buddy List data

    var buddies: [Buddy] {
        buddyIDs.compactMap { id in users[id]?.buddy(presence: presence[id] ?? .offline) }
    }

    var groups: [GroupChat] { groupOrder.compactMap(groupChat) }

    func buddy(_ id: String) -> Buddy? {
        let raw = SlackID.raw(id)
        return users[raw]?.buddy(presence: presence[raw] ?? .offline)
    }

    func group(_ id: String) -> GroupChat? { groupChat(SlackID.raw(id)) }

    /// Everyone in the workspace who can get an IM, for Quick Launch.
    var people: [Buddy] {
        users.values.filter { $0.isPerson && $0.id != rawMe }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { $0.buddy(presence: presence[$0.id] ?? .offline) }
    }

    /// The channels already loaded for Find a Chat.
    var roomList: [ChatRoom] { roomOrder.compactMap { rooms[$0] } }

    private func groupChat(_ channel: String) -> GroupChat? {
        guard let json = groupChannels[channel] else { return nil }
        let members = SlackGroupName.handles(json["name"] as? String ?? "")
            .compactMap { userByHandle[$0] }
            .filter { $0 != rawMe }
            .compactMap { buddy($0) }
        let name = members.isEmpty ? "Group Chat" : members.map(\.name).joined(separator: ", ")
        return GroupChat(id: SlackID.wrap(channel), name: name, members: members)
    }

    func recentChange(for id: String) -> BuddyChange? {
        guard let entry = recent[id], Date().timeIntervalSince(entry.date) < Self.recentInterval else { return nil }
        return entry.change
    }

    var workspace: ChatServer? {
        guard let team else { return nil }
        return ChatServer(json: ["id": SlackID.wrap(team.id), "name": team.name, "icon": team.icon?.absoluteString ?? ""])
    }

    // MARK: Presence

    /// Slack sends presence changes only over the legacy RTM API, so buddies are polled with `users.getPresence`
    /// one at a time, well inside its rate limit.
    private func startPresencePolling() {
        pollTimer?.invalidate()
        pollIndex = 0
        Task { await initialPresence(generation) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNext() }
        }
    }

    private func initialPresence(_ gen: Int) async {
        for id in buddyIDs.prefix(20) {
            guard gen == generation else { return }
            await poll(id)
        }
    }

    private func pollNext() {
        let ids = recentBuddies.map { SlackID.raw($0.id) } + buddyIDs
        guard !ids.isEmpty else { return }
        pollIndex = (pollIndex + 1) % ids.count
        let id = ids[pollIndex]
        Task { await poll(id) }
    }

    private func poll(_ id: String) async {
        guard let api, let json = try? await api.call("users.getPresence", ["user": id]), api === self.api else { return }
        update(presence: SlackPresence.parse(json["presence"] as? String), for: id)
    }

    private func update(presence new: Buddy.Presence, for id: String) {
        let old = presence[id]
        presence[id] = new
        guard old != new else { return }
        if let old, let change = BuddyChange.between(old, new), let buddy = buddy(id) {
            let now = Date()
            if change == .signedOn || change == .signedOff { recent[buddy.id] = (change, now) }
            onBuddyChange?(buddy, change)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.recentInterval + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = Date()
                    self.recent = self.recent.filter { now.timeIntervalSince($0.value.date) < Self.recentInterval }
                    self.onChange?()
                }
            }
        }
        onChange?()
    }

    // MARK: Live events

    private func startSocket() {
        guard let appToken = Self.appToken else { return }
        let socket = SlackSocket(appToken: appToken)
        socket.onEvent = { [weak self] event in self?.handle(event) }
        socket.onConnected = { [weak self] _ in self?.onChange?() }
        self.socket = socket
        socket.start()
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message":
            guard let channel = event["channel"] as? String,
                  let message = SlackMessage.parse(event, channel: channel, me: rawMe, user: { self.users[$0] }) else { return }
            deliver(message, in: channel, rawText: event["text"] as? String ?? "")
        case "reaction_added", "reaction_removed":
            guard let item = event["item"] as? [String: Any], let channel = item["channel"] as? String,
                  let ts = item["ts"] as? String else { return }
            Task { await refreshReactions(channel, ts) }
        case "user_change":
            guard let json = event["user"] as? [String: Any], let user = SlackUser(json: json) else { return }
            users[user.id] = user
            userByHandle[user.handle] = user.id
            onChange?()
        default:
            break
        }
    }

    private func refreshReactions(_ channel: String, _ ts: String) async {
        guard let api, let json = try? await api.call("reactions.get", ["channel": channel, "timestamp": ts, "full": true]),
              let message = json["message"] as? [String: Any] else { return }
        onReactions?(SlackID.wrap(channel), ts, SlackMessage.reactions(message["reactions"], me: rawMe))
    }

    /// Routes a message to the IM, group chat or room callback, the same way Discord's bridge does.
    private func deliver(_ message: DirectMessage, in channel: String, rawText: String) {
        if let root = message.reply?.id { threadRoot[message.id] = root }
        let author = SlackID.raw(message.authorID)
        if channel.hasPrefix("D") {
            if imUser[channel] == nil, author != rawMe {
                imUser[channel] = author
                imChannel[author] = channel
            }
            guard let partner = imUser[channel] else { return }
            if author != rawMe { noteRecent(partner) }
            onMessage?(SlackID.wrap(partner), message)
        } else if let chat = groupChat(channel) {
            onGroupMessage?(chat, message)
        } else if let room = rooms[channel] {
            onRoomMessage?(SlackID.wrap(channel), message)
            if author != rawMe, let workspace {
                if SlackText.mentions(rawText, userID: rawMe) {
                    onMention?(workspace, room, message)
                } else {
                    onRoomActivity?(workspace, room, message)
                }
            }
        } else {
            Task { await reloadConversations() }
        }
    }

    private func noteRecent(_ user: String) {
        guard let buddy = buddy(user) else { return }
        recentBuddies.removeAll { $0.id == buddy.id }
        recentBuddies.insert(buddy, at: 0)
        if presence[user] == nil { Task { await poll(user) } }
        onChange?()
    }

    private func reloadConversations() async {
        guard let api, let list = try? await api.paged("users.conversations",
                                                         ["types": "im,mpim,public_channel,private_channel", "exclude_archived": true],
                                                         key: "channels"), api === self.api else { return }
        apply(list)
        onChange?()
    }

    // MARK: Conversations

    /// True when an open window has not been checked against Slack for a minute. Socket Mode delivers live
    /// messages, so the 20 second Discord resync would only spend rate limit.
    func resyncDue(_ id: String) -> Bool {
        if let last = lastResync[id], Date().timeIntervalSince(last) < Self.resyncInterval { return false }
        lastResync[id] = Date()
        return true
    }

    private func channel(for target: ChatTarget) async throws -> String {
        switch target {
        case .channel(let id):
            return SlackID.raw(id)
        case .user(let id):
            let user = SlackID.raw(id)
            if let channel = imChannel[user] { return channel }
            guard let api else { throw SlackAPIError(code: "not_authed") }
            let json = try await api.call("conversations.open", ["users": user])
            guard let channel = (json["channel"] as? [String: Any])?["id"] as? String else { throw SlackAPIError(code: "bad_response") }
            imChannel[user] = channel
            imUser[channel] = user
            return channel
        }
    }

    func send(_ text: String, files: [DiscordBridge.Attachment], to target: ChatTarget, replyTo: String?,
              completion: @escaping @MainActor (Error?) -> Void) {
        guard let api else { completion(SlackError.notReady); return }
        Task {
            do {
                let channel = try await channel(for: target)
                let thread = replyTo.map { threadRoot[$0] ?? $0 }
                let body = SlackText.outgoing(text)
                if files.isEmpty {
                    var params: [String: Any] = ["channel": channel, "text": body]
                    if let thread {
                        params["thread_ts"] = thread
                        params["reply_broadcast"] = true
                    }
                    let json = try await api.call("chat.postMessage", params)
                    if let posted = json["message"] as? [String: Any],
                       let message = SlackMessage.parse(posted, channel: channel, me: rawMe, user: { self.users[$0] }) {
                        deliver(message, in: channel, rawText: posted["text"] as? String ?? "")
                    }
                } else {
                    var ids: [[String: String]] = []
                    for file in files {
                        ids.append(["id": try await api.uploadFile(name: file.name, data: file.data), "title": file.name])
                    }
                    var params: [String: Any] = ["files": ids, "channel_id": channel]
                    if !body.isEmpty { params["initial_comment"] = body }
                    if let thread { params["thread_ts"] = thread }
                    _ = try await api.call("files.completeUploadExternal", params)
                    lastResync[target.id] = nil
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func latest(in target: ChatTarget, limit: Int, completion: @escaping @MainActor (Result<[DirectMessage], Error>) -> Void) {
        guard let api else { completion(.failure(SlackError.notReady)); return }
        Task {
            do {
                let channel = try await channel(for: target)
                let json = try await api.call("conversations.history", ["channel": channel, "limit": limit])
                let list = (json["messages"] as? [[String: Any]] ?? []).reversed()
                let messages = list.compactMap { SlackMessage.parse($0, channel: channel, me: rawMe, user: { self.users[$0] }) }
                for message in messages { if let root = message.reply?.id { threadRoot[message.id] = root } }
                completion(.success(messages))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func servers(completion: @escaping @MainActor (Result<[ChatServer], Error>) -> Void) {
        completion(.success(workspace.map { [$0] } ?? []))
    }

    func rooms(in serverId: String, completion: @escaping @MainActor (Result<[ChatRoom], Error>) -> Void) {
        Task {
            await reloadConversations()
            completion(.success(roomOrder.compactMap { rooms[$0] }))
        }
    }

    /// Opens the person in the Slack app when it is installed, or the workspace in the browser.
    func openInSlack(_ userId: String) {
        guard let team else { return }
        let raw = SlackID.raw(userId)
        if let app = URL(string: "slack://user?team=\(team.id)&id=\(raw)"),
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let web = URL(string: "https://app.slack.com/client/\(team.id)/\(imChannel[raw] ?? "")") {
            NSWorkspace.shared.open(web)
        }
    }
}

enum SlackError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "Slack is not signed on. Add your Slack tokens in Settings."
    }
}

/// Slack file links need the user token. Other hosts load without it.
enum MediaAuth {
    nonisolated(unsafe) static var slackToken: String?

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = slackToken, let host = url.host?.lowercased(), host == "files.slack.com" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
