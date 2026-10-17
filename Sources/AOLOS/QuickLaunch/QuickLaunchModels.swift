import Foundation

/// A room Quick Launch can open: a Discord text or voice channel, or a Slack channel.
struct QuickRoom: Equatable {
    let id: String
    let name: String
    let serverName: String
    let voice: Bool

    init(id: String, name: String, serverName: String, voice: Bool = false) {
        self.id = id
        self.name = name
        self.serverName = serverName
        self.voice = voice
    }

    init(_ room: FavoriteRoom) {
        self.init(id: room.id, name: room.name, serverName: room.serverName, voice: room.voice)
    }

    /// The Discord bridge's `allRooms` entries: a room plus the server it belongs to.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"] as? String ?? id, serverName: json["serverName"] as? String ?? "",
                  voice: json["voice"] as? Bool ?? false)
    }

    /// "#general" or "🔊 Lounge".
    var label: String { voice ? "\u{1F50A} \(name)" : "#\(name)" }
}

/// One row in the Quick Launch list.
struct QuickLaunchItem: Equatable {
    enum Action: Equatable {
        case website(URL)
        case search(String)
        case person(Buddy)
        case room(QuickRoom)
        case keyword(String)
    }

    /// Rows are grouped under these headers, in this order.
    enum Section: Int, Comparable {
        case website, people, rooms, keywords, search

        var title: String {
            switch self {
            case .website: return "Go To"
            case .people: return "Instant Message"
            case .rooms: return "Chat Rooms"
            case .keywords: return "Keywords"
            case .search: return "Search the Web"
            }
        }

        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }

    let action: Action
    let section: Section
    let title: String
    let subtitle: String
    /// How well the row matches what was typed, from QuickLaunchMatch. Rows that are always offered score 0.
    let score: Int
}

/// What a leading character limits the list to: `@` people, `#` rooms, `?` a web search.
enum QuickLaunchScope: Equatable {
    case all, people, rooms, search

    static func parse(_ text: String) -> (scope: QuickLaunchScope, query: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch trimmed.first {
        case "@": return (.people, rest)
        case "#": return (.rooms, rest)
        case "?": return (.search, rest)
        default: return (.all, trimmed)
        }
    }
}

enum QuickLaunchMatch {
    static let exact = 100, prefix = 90, wordPrefix = 70, allWords = 60, contains = 40

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// How well `candidate` matches `query`, or nil when it does not. "gen" matches "general" (prefix),
    /// "dev" matches "ios-dev" (word prefix), "ff gen" matches "FFXI - general" (every word).
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = normalize(query), c = normalize(candidate)
        guard !q.isEmpty, !c.isEmpty else { return nil }
        if c == q { return exact }
        if c.hasPrefix(q) { return prefix }
        let cWords = words(c)
        if cWords.contains(where: { $0.hasPrefix(q) }) { return wordPrefix }
        let qWords = words(q)
        if qWords.count > 1, qWords.allSatisfy({ w in cWords.contains { $0.hasPrefix(w) } }) { return allWords }
        if c.contains(q) { return contains }
        return nil
    }

    static func best(_ query: String, _ candidates: [String]) -> Int? {
        candidates.compactMap { score(query, $0) }.max()
    }
}

/// Everything Quick Launch searches, gathered by Session from the signed on services.
struct QuickLaunchSources {
    /// Most likely first: recent conversation partners, then buddies, then everyone else the services know.
    var people: [Buddy] = []
    /// Favorite rooms first, then the rest.
    var rooms: [QuickRoom] = []
    var favoriteRoomIDs: Set<String> = []
    var keywords: [String] = []

    /// Adds people and rooms that are not already listed, keeping the existing order.
    mutating func add(people more: [Buddy]) {
        var seen = Set(people.map(\.id))
        people += more.filter { seen.insert($0.id).inserted }
    }

    mutating func add(rooms more: [QuickRoom]) {
        var seen = Set(rooms.map(\.id))
        rooms += more.filter { seen.insert($0.id).inserted }
    }
}

enum QuickLaunch {
    static let maxPeople = 5
    static let maxRooms = 5
    static let maxKeywords = 3
    static let favoriteBonus = 15

    /// Rows for the typed text, grouped by section. `url` is the web address the text would open, if any.
    static func results(for text: String, in sources: QuickLaunchSources, url: URL?) -> [QuickLaunchItem] {
        let (scope, query) = QuickLaunchScope.parse(text)
        var items: [QuickLaunchItem] = []

        if query.isEmpty {
            // Nothing typed yet: offer the usual suspects.
            if scope == .all || scope == .people {
                items += sources.people.prefix(maxPeople).map { person($0, score: 0) }
            }
            if scope == .all || scope == .rooms {
                let favorites = sources.rooms.filter { sources.favoriteRoomIDs.contains($0.id) }
                let shown = scope == .rooms && favorites.isEmpty ? Array(sources.rooms) : favorites
                items += shown.prefix(maxRooms).map { room($0, score: 0) }
            }
            return items
        }

        if scope == .all, let url {
            items.append(QuickLaunchItem(action: .website(url), section: .website, title: url.host ?? url.absoluteString,
                                         subtitle: url.absoluteString, score: QuickLaunchMatch.exact))
        }

        if scope == .all || scope == .people {
            let ranked = sources.people.enumerated().compactMap { i, buddy -> (Buddy, Int, Int)? in
                guard let s = QuickLaunchMatch.best(query, [buddy.name, buddy.username]) else { return nil }
                return (buddy, s, i)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.isOnline != b.0.isOnline { return a.0.isOnline }
                return a.2 < b.2
            }
            items += ranked.prefix(maxPeople).map { person($0.0, score: $0.1) }
        }

        if scope == .all || scope == .rooms {
            let ranked = sources.rooms.enumerated().compactMap { i, room -> (QuickRoom, Int, Int)? in
                let own = QuickLaunchMatch.score(query, room.name)
                let combined = QuickLaunchMatch.score(query, "\(room.serverName) \(room.name)").map { $0 - 10 }
                guard var s = [own, combined].compactMap({ $0 }).max() else { return nil }
                if sources.favoriteRoomIDs.contains(room.id) { s += favoriteBonus }
                return (room, s, i)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            items += ranked.prefix(maxRooms).map { room($0.0, score: min($0.1, QuickLaunchMatch.exact)) }
        }

        if scope == .all {
            let ranked = sources.keywords.compactMap { k -> (String, Int)? in
                QuickLaunchMatch.score(query, k).flatMap { $0 >= QuickLaunchMatch.prefix ? (k, $0) : nil }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            items += ranked.prefix(maxKeywords).map {
                QuickLaunchItem(action: .keyword($0.0), section: .keywords, title: $0.0, subtitle: "Keyword", score: $0.1)
            }
        }

        if scope == .all || scope == .search {
            items.append(QuickLaunchItem(action: .search(query), section: .search, title: "Search Google for \u{201C}\(query)\u{201D}",
                                         subtitle: "", score: 0))
        }
        return items
    }

    /// The row Return opens without arrowing: a web address, else the strongest name match, else the web search.
    /// Weak "somewhere in the name" matches never win over the search, so a question typed in still searches.
    static func defaultIndex(_ items: [QuickLaunchItem]) -> Int? {
        guard !items.isEmpty else { return nil }
        if let i = items.firstIndex(where: { $0.section == .website }) { return i }
        var best: Int?
        for (i, item) in items.enumerated() where item.score >= QuickLaunchMatch.wordPrefix {
            if best == nil || item.score > items[best!].score { best = i }
        }
        if let best { return best }
        return items.firstIndex { $0.section == .search } ?? 0
    }

    private static func person(_ buddy: Buddy, score: Int) -> QuickLaunchItem {
        let detail = buddy.username.isEmpty || buddy.username == buddy.name ? "" : buddy.username
        return QuickLaunchItem(action: .person(buddy), section: .people, title: buddy.name, subtitle: detail, score: score)
    }

    private static func room(_ room: QuickRoom, score: Int) -> QuickLaunchItem {
        QuickLaunchItem(action: .room(room), section: .rooms, title: room.label, subtitle: room.serverName, score: score)
    }
}
