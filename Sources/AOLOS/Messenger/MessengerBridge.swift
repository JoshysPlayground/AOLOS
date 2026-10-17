import AppKit
import WebKit

/// Messenger IDs carry this prefix everywhere outside the bridge script, so they cannot collide with Discord or
/// Slack IDs in the Buddy List, IM windows or the config.
enum MessengerID {
    static let prefix = "fb:"

    static func owns(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

/// Native side of `Scripts.messengerBridge`. Holds Facebook friends, recent chats and group chats, and talks to the
/// Messenger pane at facebook.com/messages.
@MainActor
final class MessengerBridge {
    enum State: Equatable {
        case closed
        case connecting
        case ready
        case unavailable
    }

    private(set) var state: State = .closed
    private(set) var me: (id: String, name: String, avatar: URL?)?
    private(set) var buddies: [String: Buddy] = [:]
    /// One-to-one chat partners, most recent first. They may not be friends.
    private(set) var recentBuddies: [Buddy] = []
    private(set) var groups: [GroupChat] = []
    /// People seen only through a message, such as someone who is not a friend.
    private var others: [String: Buddy] = [:]
    private var recent: [String: (change: BuddyChange, date: Date)] = [:]
    private weak var pane: WebPane?

    var onChange: (() -> Void)?
    var onReady: (() -> Void)?
    var onBuddyChange: ((Buddy, BuddyChange) -> Void)?
    var onMessage: ((String, DirectMessage) -> Void)?
    var onGroupMessage: ((GroupChat, DirectMessage) -> Void)?

    /// History loads open the thread in the Messenger window and wait for it, so they get longer than Discord calls.
    static let callTimeout: TimeInterval = 25

    nonisolated static func isMessengerHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com")
    }

    /// True for a service whose URL is the Messenger inbox on facebook.com.
    nonisolated static func isMessengerService(_ url: String) -> Bool {
        guard let url = URL(string: url), isMessengerHost(url.host) else { return false }
        return url.path.hasPrefix("/messages")
    }

    var hasPane: Bool { pane != nil }

    func buddy(_ id: String) -> Buddy? { buddies[id] ?? recentBuddies.first { $0.id == id } ?? others[id] }
    func group(_ id: String) -> GroupChat? { groups.first { $0.id == id } }

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
        me = nil
        buddies = [:]
        recentBuddies = []
        groups = []
        others = [:]
        recent = [:]
        onChange?()
    }

    func receive(_ type: String, _ body: [String: Any], from pane: WebPane) {
        attach(pane)
        switch type {
        case "messenger.ready":
            if let missing = body["missing"] as? [String], !missing.isEmpty {
                NSLog("AOL-OS: Messenger bridge is running without \(missing.joined(separator: ", "))")
            }
            state = .ready
            onChange?()
            onReady?()
        case "messenger.friends":
            state = .ready
            apply(body)
        case "messenger.message":
            guard let userId = body["userId"] as? String, let json = body["message"] as? [String: Any],
                  let message = DirectMessage(json: json) else { return }
            if let profile = (body["buddy"] as? [String: Any]).flatMap(Buddy.init(json:)), buddies[userId] == nil {
                others[userId] = profile
            }
            onMessage?(userId, message)
        case "messenger.groupMessage":
            guard let chat = (body["group"] as? [String: Any]).flatMap(GroupChat.init(json:)),
                  let json = body["message"] as? [String: Any], let message = DirectMessage(json: json) else { return }
            if let i = groups.firstIndex(where: { $0.id == chat.id }) { groups[i] = chat } else { groups.insert(chat, at: 0) }
            onGroupMessage?(chat, message)
        case "messenger.signedOff":
            me = nil
            buddies = [:]
            recentBuddies = []
            groups = []
            state = .connecting
            onChange?()
        case "messenger.unavailable":
            NSLog("AOL-OS: Messenger bridge could not find \((body["missing"] as? [String] ?? []).joined(separator: ", "))")
            state = .unavailable
            onChange?()
        default:
            break
        }
    }

    private func apply(_ body: [String: Any]) {
        if let json = body["me"] as? [String: Any], let id = json["id"] as? String {
            let avatar = (json["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            me = (id, json["name"] as? String ?? id, avatar)
        }
        let list = (body["friends"] as? [[String: Any]] ?? []).compactMap(Buddy.init(json:))
        recentBuddies = (body["recent"] as? [[String: Any]] ?? []).compactMap(Buddy.init(json:))
        groups = (body["groups"] as? [[String: Any]] ?? []).compactMap(GroupChat.init(json:))
        let firstLoad = buddies.isEmpty
        let now = Date()
        var next: [String: Buddy] = [:]
        for buddy in list {
            next[buddy.id] = buddy
            guard !firstLoad, let old = buddies[buddy.id],
                  let change = BuddyChange.between(old.presence, buddy.presence) else { continue }
            if change == .signedOn || change == .signedOff { recent[buddy.id] = (change, now) }
            onBuddyChange?(buddy, change)
        }
        buddies = next
        recent = recent.filter { now.timeIntervalSince($0.value.date) < DiscordBridge.recentInterval }
        onChange?()
        if !recent.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + DiscordBridge.recentInterval + 0.1) { [weak self] in
                guard let self else { return }
                let now = Date()
                self.recent = self.recent.filter { now.timeIntervalSince($0.value.date) < DiscordBridge.recentInterval }
                self.onChange?()
            }
        }
    }

    func recentChange(for id: String) -> BuddyChange? {
        guard let entry = recent[id], Date().timeIntervalSince(entry.date) < DiscordBridge.recentInterval else { return nil }
        return entry.change
    }

    var sortedBuddies: [Buddy] { BuddySort.sorted(Array(buddies.values)) }

    /// The newest messages in a chat. The first call for a chat opens it in the Messenger window to load them.
    func latest(in target: ChatTarget, limit: Int,
                completion: @escaping @MainActor (Result<[DirectMessage], Error>) -> Void) {
        call("return await window.__aolosMessenger.latest(target, limit);",
             ["target": target.scriptValue, "limit": limit]) { result in
            completion(result.map { ($0 as? [[String: Any]] ?? []).compactMap(DirectMessage.init(json:)) })
        }
    }

    /// Types the text into the Messenger window's message box and sends it. Files and replies are not supported.
    func send(_ text: String, files: [DiscordBridge.Attachment], to target: ChatTarget, replyTo: String?,
              completion: @escaping @MainActor (Error?) -> Void) {
        guard files.isEmpty else { completion(MessengerError.attachments); return }
        call("return await window.__aolosMessenger.send(target, text);",
             ["target": target.scriptValue, "text": text]) { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
    }

    /// Opens a chat in the Messenger window.
    func open(_ target: ChatTarget) {
        call("return await window.__aolosMessenger.open(target);", ["target": target.scriptValue]) { _ in }
    }

    private func call(_ script: String, _ arguments: [String: Any],
                      completion: @escaping @MainActor (Result<Any, Error>) -> Void) {
        guard state == .ready, let webView = pane?.webView else {
            completion(.failure(MessengerError.notReady))
            return
        }
        var finished = false
        let finish: @MainActor (Result<Any, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) {
            MainActor.assumeIsolated { finish(.failure(MessengerError.timedOut)) }
        }
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            MainActor.assumeIsolated { finish(result) }
        }
    }
}

enum MessengerError: LocalizedError {
    case notReady
    case timedOut
    case attachments

    var errorDescription: String? {
        switch self {
        case .notReady: return "Messenger is not signed on. Open the Messenger window and sign in to Facebook."
        case .timedOut: return "Messenger did not answer in time. Try again."
        case .attachments: return "Files can't be sent to Messenger buddies yet."
        }
    }
}
