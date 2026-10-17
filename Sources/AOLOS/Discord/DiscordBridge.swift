import AppKit
import WebKit

/// Native side of `Scripts.discordBridge`. Holds the friend list and talks to the Discord web pane.
@MainActor
final class DiscordBridge {
    enum State: Equatable {
        case closed
        case connecting
        case ready
        case unavailable(String)
    }

    private(set) var state: State = .closed
    private(set) var me: (id: String, name: String, avatar: URL?)?
    private(set) var buddies: [String: Buddy] = [:]
    /// Direct message partners, most recent first. They may not be friends.
    private(set) var recentBuddies: [Buddy] = []
    /// People seen only through a direct message, such as someone who is not a friend.
    private var others: [String: Buddy] = [:]
    private(set) var groups: [GroupChat] = []
    /// Recent sign on and sign off times. The Buddy List shows a door icon for a few seconds after each.
    private(set) var recent: [String: (change: BuddyChange, date: Date)] = [:]
    private weak var pane: WebPane?

    var onChange: (() -> Void)?
    var onBuddyChange: ((Buddy, BuddyChange) -> Void)?
    var onMessage: ((String, DirectMessage) -> Void)?
    var onGroupMessage: ((GroupChat, DirectMessage) -> Void)?
    var onRoomMessage: ((String, DirectMessage) -> Void)?
    var onReady: (() -> Void)?
    var onReactions: ((String, String, [MessageReaction]) -> Void)?
    var onVoiceChange: (() -> Void)?
    var onMention: ((ChatServer, ChatRoom, DirectMessage) -> Void)?
    /// A message in a server channel that has no chat room window open.
    var onRoomActivity: ((ChatServer, ChatRoom, DirectMessage) -> Void)?

    static let recentInterval: TimeInterval = 8
    static let callTimeout: TimeInterval = 15

    nonisolated static func isDiscordHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "discord.com" || host.hasSuffix(".discord.com")
    }

    var sortedBuddies: [Buddy] { BuddySort.sorted(Array(buddies.values)) }

    func group(_ id: String) -> GroupChat? { groups.first { $0.id == id } }

    func buddy(_ id: String) -> Buddy? { buddies[id] ?? recentBuddies.first { $0.id == id } ?? others[id] }
    var hasPane: Bool { pane != nil }

    func attach(_ pane: WebPane) {
        guard self.pane !== pane else { return }
        self.pane = pane
        if state == .closed { state = .connecting }
        onChange?()
    }

    func paneClosed(_ pane: WebPane) {
        guard self.pane === pane || self.pane == nil else { return }
        reset()
    }

    func reset() {
        pane = nil
        state = .closed
        buddies = [:]
        recentBuddies = []
        others = [:]
        groups = []
        recent = [:]
        me = nil
        onChange?()
    }

    func receive(_ type: String, _ body: [String: Any], from pane: WebPane) {
        attach(pane)
        switch type {
        case "discord.ready":
            if let missing = body["missing"] as? [String], !missing.isEmpty {
                NSLog("AOL-OS: Discord bridge is running without \(missing.joined(separator: ", "))")
            }
            state = .ready
            onChange?()
            onReady?()
        case "discord.friends":
            state = .ready
            apply(body)
        case "discord.message":
            guard let userId = body["userId"] as? String,
                  let json = body["message"] as? [String: Any],
                  let message = DirectMessage(json: json) else { return }
            if let profile = (body["buddy"] as? [String: Any]).flatMap(Buddy.init(json:)), buddies[userId] == nil {
                others[userId] = profile
            }
            onMessage?(userId, message)
        case "discord.groupMessage":
            guard let chat = (body["group"] as? [String: Any]).flatMap(GroupChat.init(json:)),
                  let json = body["message"] as? [String: Any],
                  let message = DirectMessage(json: json) else { return }
            if let i = groups.firstIndex(where: { $0.id == chat.id }) { groups[i] = chat } else { groups.insert(chat, at: 0) }
            onGroupMessage?(chat, message)
        case "discord.roomMessage":
            guard let channelId = body["channelId"] as? String, let json = body["message"] as? [String: Any],
                  let message = DirectMessage(json: json) else { return }
            onRoomMessage?(channelId, message)
        case "discord.reactions":
            guard let channelId = body["channelId"] as? String, let messageId = body["messageId"] as? String else { return }
            onReactions?(channelId, messageId, MessageReaction.parse(body["reactions"]))
        case "discord.mention", "discord.roomActivity":
            guard let channelId = body["channelId"] as? String, let guildId = body["guildId"] as? String,
                  let json = body["message"] as? [String: Any], let message = DirectMessage(json: json),
                  let server = ChatServer(json: ["id": guildId, "name": body["serverName"] as? String ?? ""]),
                  let room = ChatRoom(json: ["id": channelId, "name": body["roomName"] as? String ?? channelId,
                                             "category": body["categoryName"] as? String ?? "",
                                             "categoryId": body["categoryId"] as? String ?? ""]) else { return }
            if type == "discord.mention" { onMention?(server, room, message) } else { onRoomActivity?(server, room, message) }
        case "discord.voice":
            onVoiceChange?()
        case "discord.signedOff":
            buddies = [:]
            me = nil
            state = .connecting
            onChange?()
        case "discord.unavailable":
            let missing = (body["missing"] as? [String] ?? []).joined(separator: ", ")
            NSLog("AOL-OS: Discord bridge could not find \(missing) in \(body["modules"] ?? 0) modules. \(body["error"] ?? "")")
            state = .unavailable(missing)
            onChange?()
        default:
            break
        }
    }

    private func apply(_ body: [String: Any]) {
        if let json = body["me"] as? [String: Any], let id = json["id"] as? String {
            me = (id, json["name"] as? String ?? id, (json["avatar"] as? String).flatMap(URL.init(string:)))
        }
        let list = (body["friends"] as? [[String: Any]] ?? []).compactMap(Buddy.init(json:))
        recentBuddies = (body["recent"] as? [[String: Any]] ?? []).compactMap(Buddy.init(json:))
        groups = (body["groups"] as? [[String: Any]] ?? []).compactMap(GroupChat.init(json:))
        let firstLoad = buddies.isEmpty
        var next: [String: Buddy] = [:]
        let now = Date()
        for buddy in list {
            next[buddy.id] = buddy
            guard !firstLoad, let old = buddies[buddy.id],
                  let change = BuddyChange.between(old.presence, buddy.presence) else { continue }
            if change == .signedOn || change == .signedOff { recent[buddy.id] = (change, now) }
            onBuddyChange?(buddy, change)
        }
        buddies = next
        recent = recent.filter { now.timeIntervalSince($0.value.date) < Self.recentInterval }
        onChange?()
        if !recent.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.recentInterval + 0.1) { [weak self] in
                guard let self else { return }
                let now = Date()
                self.recent = self.recent.filter { now.timeIntervalSince($0.value.date) < Self.recentInterval }
                self.onChange?()
            }
        }
    }

    func recentChange(for id: String) -> BuddyChange? {
        guard let entry = recent[id], Date().timeIntervalSince(entry.date) < Self.recentInterval else { return nil }
        return entry.change
    }

    func history(with target: ChatTarget, limit: Int = 30,
                 completion: @escaping @MainActor (Result<[DirectMessage], Error>) -> Void) {
        call("return await window.__aolosDiscord.history(target, limit);",
             ["target": target.scriptValue, "limit": limit]) { result in
            completion(result.map { value in
                (value as? [[String: Any]] ?? []).compactMap(DirectMessage.init(json:))
            })
        }
    }

    func send(_ text: String, to target: ChatTarget, replyTo: String? = nil,
              completion: @escaping @MainActor (Error?) -> Void) {
        call("return await window.__aolosDiscord.send(target, content, replyTo);",
             ["target": target.scriptValue, "content": text, "replyTo": replyTo ?? NSNull()]) { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
    }

    /// A file dropped on an IM window, sent as a Discord attachment.
    struct Attachment {
        let name: String
        let type: String
        let data: Data
    }

    func send(_ text: String, files: [Attachment], to target: ChatTarget, replyTo: String? = nil,
              completion: @escaping @MainActor (Error?) -> Void) {
        guard !files.isEmpty else { send(text, to: target, replyTo: replyTo, completion: completion); return }
        let payload = files.map { ["name": $0.name, "type": $0.type, "data": $0.data.base64EncodedString()] }
        call("return await window.__aolosDiscord.upload(target, content, files, replyTo);",
             ["target": target.scriptValue, "content": text, "files": payload, "replyTo": replyTo ?? NSNull()]) { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
    }

    /// The newest messages from Discord's API, to fill gaps the live events missed.
    func latest(in target: ChatTarget, limit: Int = 20,
                completion: @escaping @MainActor (Result<[DirectMessage], Error>) -> Void) {
        call("return await window.__aolosDiscord.latest(target, limit);",
             ["target": target.scriptValue, "limit": limit]) { result in
            completion(result.map { ($0 as? [[String: Any]] ?? []).compactMap(DirectMessage.init(json:)) })
        }
    }

    /// Connects the Discord window to a voice channel, or disconnects with nil.
    func joinVoice(_ channelId: String?) {
        call("return window.__aolosDiscord.joinVoice(c);", ["c": channelId ?? NSNull()]) { _ in }
    }

    func servers(completion: @escaping @MainActor (Result<[ChatServer], Error>) -> Void) {
        call("return window.__aolosDiscord.servers();", [:]) { result in
            completion(result.map { ($0 as? [[String: Any]] ?? []).compactMap(ChatServer.init(json:)) })
        }
    }

    func rooms(in serverId: String, completion: @escaping @MainActor (Result<[ChatRoom], Error>) -> Void) {
        call("return window.__aolosDiscord.rooms(guildId);", ["guildId": serverId]) { result in
            completion(result.map { ($0 as? [[String: Any]] ?? []).compactMap(ChatRoom.init(json:)) })
        }
    }

    /// Every text and voice room across all servers, with each room's server name.
    func allRooms(completion: @escaping @MainActor (Result<[QuickRoom], Error>) -> Void) {
        call("return window.__aolosDiscord.allRooms();", [:]) { result in
            completion(result.map { ($0 as? [[String: Any]] ?? []).compactMap(QuickRoom.init(json:)) })
        }
    }

    /// People the Discord client has loaded whose name matches, friends or not.
    func searchPeople(_ query: String, limit: Int = 8, completion: @escaping @MainActor ([Buddy]) -> Void) {
        call("return window.__aolosDiscord.searchUsers(q, limit);", ["q": query, "limit": limit]) { result in
            completion((try? result.get()).flatMap { $0 as? [[String: Any]] }?.compactMap(Buddy.init(json:)) ?? [])
        }
    }

    /// Keeps a non-friend picked in Quick Launch resolvable, so their IM window keeps its name and presence.
    func remember(_ buddy: Buddy) {
        guard buddies[buddy.id] == nil else { return }
        others[buddy.id] = buddy
    }

    /// Live messages from a server channel only arrive while it is watched.
    func watch(_ channelId: String, _ on: Bool) {
        call(on ? "return window.__aolosDiscord.watch(c);" : "return window.__aolosDiscord.unwatch(c);", ["c": channelId]) { _ in }
    }

    func openInDiscord(_ userId: String) {
        call("return window.__aolosDiscord.open(userId);", ["userId": userId]) { _ in }
    }

    private func call(_ script: String, _ arguments: [String: Any],
                      completion: @escaping @MainActor (Result<Any, Error>) -> Void) {
        guard state == .ready, let webView = pane?.webView else {
            completion(.failure(DiscordError.notReady))
            return
        }
        // A page promise that never settles would otherwise leave the caller waiting, such as an IM stuck busy.
        var finished = false
        let finish: @MainActor (Result<Any, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) {
            MainActor.assumeIsolated { finish(.failure(DiscordError.timedOut)) }
        }
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            MainActor.assumeIsolated { finish(result) }
        }
    }
}

enum DiscordError: LocalizedError {
    case notReady
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notReady: return "Discord is not signed on. Open People Connection and sign in to Discord."
        case .timedOut: return "Discord did not answer in time. Try again."
        }
    }
}
