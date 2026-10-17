import Foundation

/// Slack IDs carry a `slack:` prefix everywhere outside the Slack client, so a window, a hidden buddy or a favorite
/// room can tell which service owns it. Discord IDs are bare numbers.
enum SlackID {
    static let prefix = "slack:"

    static func wrap(_ raw: String) -> String { prefix + raw }

    static func raw(_ id: String) -> String { owns(id) ? String(id.dropFirst(prefix.count)) : id }

    static func owns(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

/// A workspace member from `users.list` or a `user_change` event.
struct SlackUser: Equatable {
    let id: String
    let handle: String
    let displayName: String
    let avatarURL: URL?
    let status: String
    let isBot: Bool
    let deleted: Bool

    var name: String { displayName.isEmpty ? handle : displayName }

    /// Slackbot and app bots never answer an IM, so they stay off the Buddy List.
    var isPerson: Bool { !isBot && !deleted && id != "USLACKBOT" }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let profile = json["profile"] as? [String: Any] ?? [:]
        self.id = id
        handle = json["name"] as? String ?? id
        let display = profile["display_name"] as? String ?? ""
        let real = profile["real_name"] as? String ?? json["real_name"] as? String ?? ""
        displayName = display.isEmpty ? real : display
        avatarURL = (profile["image_48"] as? String ?? profile["image_72"] as? String).flatMap(URL.init(string:))
        let emoji = SlackEmoji.render(profile["status_emoji"] as? String ?? "")
        let text = profile["status_text"] as? String ?? ""
        status = [emoji, text].filter { !$0.isEmpty }.joined(separator: " ")
        isBot = json["is_bot"] as? Bool ?? false
        deleted = json["deleted"] as? Bool ?? false
    }

    func buddy(presence: Buddy.Presence) -> Buddy {
        Buddy(id: SlackID.wrap(id), name: name, username: handle, avatarURL: avatarURL, presence: presence, activity: status)
    }
}

enum SlackPresence {
    /// `users.getPresence` reports `active` or `away` for other people. Away covers both signed off and idle, so it
    /// shows as signed off, the way AIM showed a buddy with no client running.
    static func parse(_ value: String?) -> Buddy.Presence {
        value == "active" ? .online : .offline
    }
}

/// Group direct messages are named after their members, such as `mpdm-alice--bob--carol-1`.
enum SlackGroupName {
    static func handles(_ name: String) -> [String] {
        var body = Substring(name)
        guard body.hasPrefix("mpdm-") else { return [] }
        body = body.dropFirst(5)
        if let dash = body.lastIndex(of: "-"), body[body.index(after: dash)...].allSatisfy(\.isNumber),
           dash != body.startIndex, body[body.index(before: dash)] != "-" {
            body = body[..<dash]
        }
        return body.components(separatedBy: "--").filter { !$0.isEmpty }
    }
}

/// Common Slack emoji short names drawn as the emoji itself. Others stay as `:name:`.
enum SlackEmoji {
    static let table: [String: String] = [
        "smile": "\u{1F604}", "slightly_smiling_face": "\u{1F642}", "grinning": "\u{1F600}", "joy": "\u{1F602}",
        "laughing": "\u{1F606}", "wink": "\u{1F609}", "sob": "\u{1F62D}", "thinking_face": "\u{1F914}",
        "+1": "\u{1F44D}", "thumbsup": "\u{1F44D}", "-1": "\u{1F44E}", "thumbsdown": "\u{1F44E}",
        "heart": "\u{2764}\u{FE0F}", "tada": "\u{1F389}", "wave": "\u{1F44B}", "pray": "\u{1F64F}",
        "fire": "\u{1F525}", "eyes": "\u{1F440}", "white_check_mark": "\u{2705}", "100": "\u{1F4AF}",
        "ok_hand": "\u{1F44C}", "clap": "\u{1F44F}", "rocket": "\u{1F680}", "raised_hands": "\u{1F64C}",
        "sweat_smile": "\u{1F605}", "rolling_on_the_floor_laughing": "\u{1F923}", "heart_eyes": "\u{1F60D}",
        "sunglasses": "\u{1F60E}", "cry": "\u{1F622}", "x": "\u{274C}", "warning": "\u{26A0}\u{FE0F}",
        "palm_tree": "\u{1F334}", "house_with_garden": "\u{1F3E1}", "spiral_calendar_pad": "\u{1F5D3}\u{FE0F}",
        "face_with_thermometer": "\u{1F912}", "headphones": "\u{1F3A7}", "coffee": "\u{2615}",
    ]

    /// Accepts `smile`, `:smile:` or `:+1::skin-tone-2:`.
    static func render(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !trimmed.isEmpty else { return "" }
        let base = trimmed.components(separatedBy: "::").first ?? trimmed
        return table[base] ?? ":\(base):"
    }

    static func replaceCodes(in text: String) -> String {
        guard text.contains(":"), let regex = try? NSRegularExpression(pattern: ":([a-z0-9_+\\-]+):") else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out), let name = Range(match.range(at: 1), in: text),
                  let emoji = table[String(text[name])] else { continue }
            out.replaceSubrange(range, with: emoji)
        }
        return out
    }
}

/// Converts between Slack's message markup and the plain text an IM window shows.
enum SlackText {
    /// Resolves `<@U1>`, `<#C1|name>`, `<!here>` and `<url|label>` and unescapes `&amp;`, `&lt;` and `&gt;`.
    static func plain(_ text: String, userName: (String) -> String?) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            out += rest[..<open]
            out += token(String(rest[rest.index(after: open)..<close]), userName: userName)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return SlackEmoji.replaceCodes(in: unescape(out))
    }

    private static func token(_ body: String, userName: (String) -> String?) -> String {
        let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
        let target = parts[0]
        let label = parts.count > 1 ? parts[1] : nil
        if target.hasPrefix("@") {
            let id = String(target.dropFirst())
            return "@" + (userName(id) ?? label ?? id)
        }
        if target.hasPrefix("#") { return "#" + (label ?? String(target.dropFirst())) }
        if target.hasPrefix("!") {
            if let label { return label }
            let command = target.dropFirst().split(separator: "^").first.map(String.init) ?? ""
            return "@" + command
        }
        if target.hasPrefix("mailto:") { return label ?? String(target.dropFirst(7)) }
        guard let label, label != target else { return target }
        return "\(label) (\(target))"
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Escapes control characters and turns the IM format bar's markers into Slack's: `**b**` to `*b*`, `*i*` to
    /// `_i_` and `~~s~~` to `~s~`. Slack has no underline, so `__u__` loses its markers.
    static func outgoing(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        out = replace(out, "\\*\\*(.+?)\\*\\*", "\u{1}$1\u{1}")
        out = replace(out, "\\*([^*\\n]+?)\\*", "_$1_")
        out = replace(out, "~~(.+?)~~", "~$1~")
        out = replace(out, "__(.+?)__", "$1")
        return out.replacingOccurrences(of: "\u{1}", with: "*")
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// True when the raw message text mentions the user by ID.
    static func mentions(_ text: String, userID: String) -> Bool {
        text.contains("<@\(userID)>") || text.contains("<@\(userID)|")
    }
}

/// Builds a `DirectMessage` from a Slack message object.
enum SlackMessage {
    /// Joins, topic changes and edits carry a subtype and stay out of the transcript.
    static let shownSubtypes: Set<String> = ["file_share", "thread_broadcast", "me_message", "bot_message"]

    static func parse(_ json: [String: Any], channel: String, me: String,
                      user: (String) -> SlackUser?) -> DirectMessage? {
        if let subtype = json["subtype"] as? String, !shownSubtypes.contains(subtype) { return nil }
        guard let ts = json["ts"] as? String, let seconds = Double(ts) else { return nil }
        let author = json["user"] as? String ?? json["bot_id"] as? String ?? ""
        let botName = (json["bot_profile"] as? [String: Any])?["name"] as? String ?? json["username"] as? String
        let name: (String) -> String? = { user($0)?.name }
        var message = DirectMessage(id: ts, authorID: SlackID.wrap(author),
                                    text: plain(json["text"] as? String ?? "", name: name),
                                    date: Date(timeIntervalSince1970: seconds))
        message.authorName = user(author)?.name ?? botName ?? author
        message.channelID = SlackID.wrap(channel)
        if let root = json["thread_ts"] as? String, root != ts {
            let parent = (json["parent_user_id"] as? String).flatMap(name) ?? ""
            message.reply = MessageReply(json: ["id": root, "authorName": parent, "text": "in thread"])
        }
        message.reactions = reactions(json["reactions"], me: me)
        for file in json["files"] as? [[String: Any]] ?? [] {
            let fileName = file["name"] as? String ?? file["title"] as? String ?? "file"
            if (file["mimetype"] as? String ?? "").hasPrefix("image/"),
               let media = MessageMedia(json: ["url": file["thumb_720"] ?? file["url_private"] ?? "", "name": fileName,
                                               "width": file["original_w"] ?? 0, "height": file["original_h"] ?? 0]) {
                message.images.append(media)
            } else if let media = MessageMedia(json: ["url": file["permalink"] ?? file["url_private"] ?? "", "name": fileName]) {
                message.files.append(media)
            }
        }
        return message
    }

    static func plain(_ text: String, name: (String) -> String?) -> String {
        SlackText.plain(text, userName: name)
    }

    static func reactions(_ list: Any?, me: String) -> [MessageReaction] {
        (list as? [[String: Any]] ?? []).compactMap { json in
            guard let name = json["name"] as? String else { return nil }
            let users = json["users"] as? [String] ?? []
            return MessageReaction(json: ["name": SlackEmoji.render(name), "count": json["count"] ?? users.count,
                                          "me": users.contains(me)])
        }
    }
}
