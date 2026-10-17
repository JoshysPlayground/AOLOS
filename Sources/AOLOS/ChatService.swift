import AppKit

/// What an IM, group chat or room window needs from the service that owns it. Discord, Slack and Messenger conform, and
/// Session picks one by the conversation's ID.
@MainActor
protocol ChatService: AnyObject {
    var isReady: Bool { get }
    var myID: String? { get }
    var myName: String { get }
    func buddy(_ id: String) -> Buddy?
    func group(_ id: String) -> GroupChat?
    func send(_ text: String, files: [DiscordBridge.Attachment], to target: ChatTarget, replyTo: String?,
              completion: @escaping @MainActor (Error?) -> Void)
    func latest(in target: ChatTarget, limit: Int, completion: @escaping @MainActor (Result<[DirectMessage], Error>) -> Void)
    func rooms(in serverId: String, completion: @escaping @MainActor (Result<[ChatRoom], Error>) -> Void)
    func watch(_ channelId: String, _ on: Bool)
    func openInApp(_ userId: String)
}

extension DiscordBridge: ChatService {
    var isReady: Bool { state == .ready }
    var myID: String? { me?.id }
    var myName: String { me?.name ?? "" }
    func openInApp(_ userId: String) { openInDiscord(userId) }
}

extension SlackClient: ChatService {
    var isReady: Bool { state == .ready }
    var myID: String? { me?.id }
    var myName: String { me?.name ?? "" }
    func watch(_ channelId: String, _ on: Bool) {}
    func openInApp(_ userId: String) { openInSlack(userId) }
}

/// The service a buddy, chat or room belongs to, shown as a small colored tag when more than one is signed on.
enum ChatServiceKind {
    case discord, slack, messenger

    init(id: String) {
        if SlackID.owns(id) {
            self = .slack
        } else if MessengerID.owns(id) {
            self = .messenger
        } else {
            self = .discord
        }
    }

    var name: String {
        switch self {
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .messenger: return "Messenger"
        }
    }

    var color: NSColor {
        switch self {
        case .discord: return Theme.rgb(88, 101, 242)
        case .slack: return Theme.rgb(74, 21, 75)
        case .messenger: return Theme.rgb(0, 132, 255)
        }
    }
}

/// The Find a Chat status line, such as "1 workspace, 4 servers".
enum ChatRoomCount {
    static func status(workspaces: Int, servers: Int) -> String {
        var parts: [String] = []
        if workspaces > 0 { parts.append(workspaces == 1 ? "1 workspace" : "\(workspaces) workspaces") }
        if servers > 0 || parts.isEmpty { parts.append(servers == 1 ? "1 server" : "\(servers) servers") }
        return parts.joined(separator: ", ")
    }
}
