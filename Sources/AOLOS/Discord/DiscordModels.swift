import Foundation

/// A Discord friend as the bridge script reports it in `discord.friends`.
struct Buddy: Equatable {
    enum Presence: String {
        case online, idle, dnd, offline
    }

    let id: String
    let name: String
    let username: String
    let avatarURL: URL?
    let presence: Presence
    /// True when the only active Discord client is the mobile app.
    let mobileOnly: Bool
    let activity: String

    var isOnline: Bool { presence != .offline }

    init(id: String, name: String, username: String = "", avatarURL: URL? = nil,
         presence: Presence, mobileOnly: Bool = false, activity: String = "") {
        self.id = id
        self.name = name
        self.username = username
        self.avatarURL = avatarURL
        self.presence = presence
        self.mobileOnly = mobileOnly
        self.activity = activity
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let status = json["status"] as? String ?? "offline"
        let presence = Presence(rawValue: status) ?? .offline
        let mobile = !(json["mobile"] as? String ?? "").isEmpty
        let desktop = !(json["desktop"] as? String ?? "").isEmpty
        let web = !(json["web"] as? String ?? "").isEmpty
        self.init(id: id,
                  name: json["name"] as? String ?? id,
                  username: json["username"] as? String ?? "",
                  avatarURL: (json["avatar"] as? String).flatMap(URL.init(string:)),
                  presence: presence,
                  mobileOnly: presence != .offline && mobile && !desktop && !web,
                  activity: json["activity"] as? String ?? "")
    }
}

/// A presence change worth announcing with a sound.
enum BuddyChange: Equatable {
    case signedOn, signedOff, away, back

    var sound: SoundEvent {
        switch self {
        case .signedOn: return .buddyIn
        case .signedOff: return .buddyOut
        case .away: return .doorClose
        case .back: return .doorOpen
        }
    }

    var verb: String {
        switch self {
        case .signedOn: return "signed on"
        case .signedOff: return "signed off"
        case .away: return "is away"
        case .back: return "is back"
        }
    }

    /// Discord reports idle when a buddy has been away from the keyboard. Do Not Disturb counts as active.
    static func between(_ old: Buddy.Presence, _ new: Buddy.Presence) -> BuddyChange? {
        switch (old, new) {
        case (.offline, .offline): return nil
        case (.offline, _): return .signedOn
        case (_, .offline): return .signedOff
        case (.idle, .online), (.idle, .dnd): return .back
        case (.online, .idle), (.dnd, .idle): return .away
        default: return nil
        }
    }
}

/// An image or file attached to a direct message.
struct MessageMedia: Equatable {
    let url: URL
    let name: String
    let size: CGSize

    init?(json: [String: Any]) {
        guard let string = json["url"] as? String, let url = URL(string: string),
              ["https", "http"].contains(url.scheme ?? "") else { return nil }
        self.url = url
        name = json["name"] as? String ?? ""
        size = CGSize(width: (json["width"] as? NSNumber)?.doubleValue ?? 0,
                      height: (json["height"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Fits the image inside the transcript, never scaling it up.
    static func displaySize(for size: CGSize, maxWidth: CGFloat = 260, maxHeight: CGFloat = 220) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 160, height: 120) }
        let scale = min(1, maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// One direct message as the bridge reports it.
struct DirectMessage: Equatable {
    let id: String
    let authorID: String
    let text: String
    let date: Date
    /// The author's display name. Group chats need it because the author varies.
    var authorName = ""
    var images: [MessageMedia] = []
    var files: [MessageMedia] = []

    init(id: String, authorID: String, text: String, date: Date) {
        self.id = id
        self.authorID = authorID
        self.text = text
        self.date = date
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let millis = (json["time"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        self.init(id: id, authorID: json["authorID"] as? String ?? "", text: json["text"] as? String ?? "",
                  date: Date(timeIntervalSince1970: millis / 1000))
        authorName = json["authorName"] as? String ?? ""
        images = (json["images"] as? [[String: Any]] ?? []).compactMap(MessageMedia.init(json:))
        files = (json["files"] as? [[String: Any]] ?? []).compactMap(MessageMedia.init(json:))
    }
}

/// A Discord group direct message.
struct GroupChat: Equatable {
    let id: String
    let name: String
    let members: [Buddy]

    init(id: String, name: String, members: [Buddy]) {
        self.id = id
        self.name = name
        self.members = members
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"] as? String ?? "Group Chat",
                  members: (json["members"] as? [[String: Any]] ?? []).compactMap(Buddy.init(json:)))
    }

    var onlineCount: Int { members.filter(\.isOnline).count }
}

/// Who a message goes to: one person, or a group chat channel.
enum ChatTarget: Equatable {
    case user(String)
    case channel(String)

    var id: String {
        switch self {
        case .user(let id), .channel(let id): return id
        }
    }

    /// The value `channelFor` in the bridge script expects.
    var scriptValue: Any {
        switch self {
        case .user(let id): return id
        case .channel(let id): return ["channelId": id]
        }
    }
}

/// The Recent Buddies group: the latest direct message partners, online or not, minus hidden buddies.
enum RecentBuddies {
    static let limit = 8

    static func pick(_ recent: [Buddy], hidden: Set<String>) -> [Buddy] {
        var seen = Set<String>()
        return Array(recent.filter { !hidden.contains($0.id) && seen.insert($0.id).inserted }.prefix(limit))
    }
}

/// Friends sorted the way the Buddy List shows them: online first, then by name.
enum BuddySort {
    static func sorted(_ buddies: [Buddy]) -> [Buddy] {
        buddies.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
