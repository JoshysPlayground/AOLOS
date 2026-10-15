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
    /// Recent sign on and sign off times. The Buddy List shows a door icon for a few seconds after each.
    private(set) var recent: [String: (change: BuddyChange, date: Date)] = [:]
    private weak var pane: WebPane?

    var onChange: (() -> Void)?
    var onBuddyChange: ((Buddy, BuddyChange) -> Void)?
    var onMessage: ((String, DirectMessage) -> Void)?

    static let recentInterval: TimeInterval = 8

    nonisolated static func isDiscordHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "discord.com" || host.hasSuffix(".discord.com")
    }

    var sortedBuddies: [Buddy] { BuddySort.sorted(Array(buddies.values)) }
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
        case "discord.friends":
            state = .ready
            apply(body)
        case "discord.message":
            guard let userId = body["userId"] as? String,
                  let json = body["message"] as? [String: Any],
                  let message = DirectMessage(json: json) else { return }
            onMessage?(userId, message)
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

    func history(with userId: String, limit: Int = 30,
                 completion: @escaping @MainActor (Result<[DirectMessage], Error>) -> Void) {
        call("return await window.__aolosDiscord.history(userId, limit);",
             ["userId": userId, "limit": limit]) { result in
            completion(result.map { value in
                (value as? [[String: Any]] ?? []).compactMap(DirectMessage.init(json:))
            })
        }
    }

    func send(_ text: String, to userId: String, completion: @escaping @MainActor (Error?) -> Void) {
        call("return await window.__aolosDiscord.send(userId, content);", ["userId": userId, "content": text]) { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
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
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            MainActor.assumeIsolated { completion(result) }
        }
    }
}

enum DiscordError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: return "Discord is not signed on. Open People Connection and sign in to Discord."
        }
    }
}
