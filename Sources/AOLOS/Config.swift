import Foundation

struct ServiceDef: Codable, Equatable {
    var id: String
    var title: String
    var url: String
    /// Services that share a profile share cookies and logins.
    var profile: String
    var icon: String
    /// Sound played when the page posts a web notification.
    var notifySound: String?
    /// Sound played when the unread count in the page title goes up.
    var badgeSound: String?
    var hooks: Bool?
    var autofill: Bool?

    var wantsHooks: Bool { hooks ?? true }
    var wantsAutofill: Bool { autofill ?? true }
}

struct AOLConfig: Codable {
    var screenName = NSUserName()
    var requireTouchID = true
    var soundsEnabled = true
    var openAtSignOn = ["mail"]
    var services = AOLConfig.defaultServices
    var keywords = AOLConfig.defaultKeywords
    var neverSaveHosts: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AOLConfig()
        screenName = try c.decodeIfPresent(String.self, forKey: .screenName) ?? d.screenName
        requireTouchID = try c.decodeIfPresent(Bool.self, forKey: .requireTouchID) ?? d.requireTouchID
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? d.soundsEnabled
        openAtSignOn = try c.decodeIfPresent([String].self, forKey: .openAtSignOn) ?? d.openAtSignOn
        services = try c.decodeIfPresent([ServiceDef].self, forKey: .services) ?? d.services
        keywords = try c.decodeIfPresent([String: String].self, forKey: .keywords) ?? d.keywords
        neverSaveHosts = try c.decodeIfPresent([String].self, forKey: .neverSaveHosts) ?? d.neverSaveHosts
    }

    func service(_ id: String) -> ServiceDef? { services.first { $0.id == id } }

    mutating func update(_ service: ServiceDef) {
        if let i = services.firstIndex(where: { $0.id == service.id }) {
            services[i] = service
        } else {
            services.append(service)
        }
    }

    static let defaultServices: [ServiceDef] = [
        ServiceDef(id: "mail", title: "Mail", url: "https://mail.google.com/mail/u/0/#inbox",
                   profile: "google", icon: "envelope.fill", notifySound: "gotmail", badgeSound: "gotmail"),
        ServiceDef(id: "write", title: "Write Mail", url: "https://mail.google.com/mail/u/0/#inbox?compose=new",
                   profile: "google", icon: "square.and.pencil"),
        ServiceDef(id: "chat", title: "People Connection", url: "https://discord.com/channels/@me",
                   profile: "discord", icon: "bubble.left.and.bubble.right.fill", notifySound: "imrcv"),
        ServiceDef(id: "im", title: "Instant Message", url: "https://app.slack.com/client",
                   profile: "slack", icon: "message.fill", notifySound: "imrcv"),
        ServiceDef(id: "ytmusic", title: "YouTube Music", url: "https://music.youtube.com",
                   profile: "google", icon: "music.note"),
        ServiceDef(id: "spotify", title: "Spotify", url: "https://open.spotify.com",
                   profile: "spotify", icon: "headphones"),
        ServiceDef(id: "finance", title: "Finance", url: "",
                   profile: "bank", icon: "dollarsign.circle.fill", hooks: false, autofill: true),
    ]

    static let defaultKeywords: [String: String] = [
        "mail": "mail", "gmail": "mail", "write": "write",
        "chat": "chat", "discord": "chat", "people": "chat",
        "im": "im", "aim": "im", "slack": "im",
        "music": "ytmusic", "ytmusic": "ytmusic", "youtube music": "ytmusic", "spotify": "spotify",
        "finance": "finance", "bank": "finance",
        "welcome": "welcome", "settings": "settings",
    ]
}

enum ConfigStore {
    static func load() -> AOLConfig {
        let url = AppPaths.config
        guard let data = try? Data(contentsOf: url) else {
            let config = AOLConfig()
            save(config)
            return config
        }
        do {
            return try JSONDecoder().decode(AOLConfig.self, from: data)
        } catch {
            NSLog("AOL-OS: config.json is invalid, using defaults without overwriting it: \(error)")
            return AOLConfig()
        }
    }

    static func save(_ config: AOLConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: AppPaths.config, options: .atomic)
    }
}
