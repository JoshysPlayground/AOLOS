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
    /// Web pages get `prefers-color-scheme: dark`.
    var darkWebPages = false
    /// Experimental dark theme for AOL-OS itself.
    var darkTheme = false
    var openAtSignOn = ["mail"]
    var services = AOLConfig.defaultServices
    var keywords = AOLConfig.defaultKeywords
    var neverSaveHosts: [String] = []
    var radioPresets: [RadioStation] = []
    /// Buddy IDs left off the Buddy List. Slack IDs start with `slack:` and Messenger IDs with `fb:`.
    var hiddenBuddies: [String] = []
    /// Favorite Discord channels, in the order they were added. Listed under People > Favorites
    /// and pinned to the top of their server's room list.
    var favoriteRooms: [FavoriteRoom] = []
    /// Muted server, category and room IDs. See `ChatMute`.
    var mutedRooms: [String] = []
    /// Saved pages in the Favorites menu, in menu order.
    var favorites: [Favorite] = []
    var screenNames: [String] = []
    var signOnLocation = "Home (Broadband)"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AOLConfig()
        screenName = try c.decodeIfPresent(String.self, forKey: .screenName) ?? d.screenName
        requireTouchID = try c.decodeIfPresent(Bool.self, forKey: .requireTouchID) ?? d.requireTouchID
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? d.soundsEnabled
        darkWebPages = try c.decodeIfPresent(Bool.self, forKey: .darkWebPages) ?? d.darkWebPages
        darkTheme = try c.decodeIfPresent(Bool.self, forKey: .darkTheme) ?? d.darkTheme
        openAtSignOn = try c.decodeIfPresent([String].self, forKey: .openAtSignOn) ?? d.openAtSignOn
        services = try c.decodeIfPresent([ServiceDef].self, forKey: .services) ?? d.services
        for service in d.services where !services.contains(where: { $0.id == service.id }) {
            services.append(service)
        }
        keywords = try c.decodeIfPresent([String: String].self, forKey: .keywords) ?? d.keywords
        neverSaveHosts = try c.decodeIfPresent([String].self, forKey: .neverSaveHosts) ?? d.neverSaveHosts
        radioPresets = try c.decodeIfPresent([RadioStation].self, forKey: .radioPresets) ?? d.radioPresets
        hiddenBuddies = try c.decodeIfPresent([String].self, forKey: .hiddenBuddies) ?? d.hiddenBuddies
        favoriteRooms = (try? c.decodeIfPresent([FavoriteRoom].self, forKey: .favoriteRooms)) ?? d.favoriteRooms
        mutedRooms = try c.decodeIfPresent([String].self, forKey: .mutedRooms) ?? d.mutedRooms
        favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? d.favorites
        screenNames = try c.decodeIfPresent([String].self, forKey: .screenNames) ?? d.screenNames
        signOnLocation = try c.decodeIfPresent(String.self, forKey: .signOnLocation) ?? d.signOnLocation
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
        ServiceDef(id: "messenger", title: "Messenger", url: "https://www.facebook.com/messages/t/",
                   profile: "facebook", icon: "bolt.horizontal.circle.fill", notifySound: "imrcv"),
        ServiceDef(id: "im", title: "Instant Message", url: "https://app.slack.com/client",
                   profile: "slack", icon: "message.fill", notifySound: "imrcv"),
        ServiceDef(id: "ytmusic", title: "YouTube Music", url: "https://music.youtube.com",
                   profile: "google", icon: "music.note"),
        ServiceDef(id: "spotify", title: "Spotify", url: "https://open.spotify.com",
                   profile: "spotify", icon: "headphones"),
        ServiceDef(id: "finance", title: "Finance", url: "",
                   profile: "bank", icon: "dollarsign.circle.fill", hooks: false, autofill: true),
        ServiceDef(id: "photos", title: "Pictures", url: "https://photos.google.com",
                   profile: "google", icon: "photo.on.rectangle"),
        ServiceDef(id: "news", title: "Buzzline", url: "https://news.google.com",
                   profile: "google", icon: "bubble.left.fill"),
        ServiceDef(id: "calendar", title: "Remind Me", url: "https://calendar.google.com",
                   profile: "google", icon: "calendar"),
        ServiceDef(id: "movies", title: "Moviefone", url: "https://www.fandango.com",
                   profile: "browser", icon: "popcorn.fill"),
        ServiceDef(id: "crunchyroll", title: "Crunchyroll", url: "https://www.crunchyroll.com",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "netflix", title: "Netflix", url: "https://www.netflix.com",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "hulu", title: "Hulu", url: "https://www.hulu.com",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "disneyplus", title: "Disney+", url: "https://www.disneyplus.com",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "primevideo", title: "Prime Video", url: "https://www.amazon.com/gp/video/storefront",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "youtube", title: "YouTube", url: "https://www.youtube.com",
                   profile: "google", icon: "play.rectangle.fill"),
        ServiceDef(id: "hbomax", title: "HBO Max", url: "https://www.hbomax.com",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "peacock", title: "Peacock", url: "https://www.peacocktv.com",
                   profile: "streaming", icon: "play.tv.fill"),
        ServiceDef(id: "appletv", title: "Apple TV", url: "https://tv.apple.com",
                   profile: "streaming", icon: "appletv.fill"),
    ]

    /// Entertainment menu order. The first four show directly. The rest go under More.
    static let entertainmentServices = ["crunchyroll", "netflix", "hulu", "disneyplus",
                                        "primevideo", "youtube", "hbomax", "peacock", "appletv"]

    static let defaultKeywords: [String: String] = [
        "mail": "mail", "gmail": "mail", "write": "write",
        "chat": "chat", "discord": "chat", "people": "chat",
        "im": "im", "slack": "im", "messenger": "messenger", "facebook": "messenger",
        "buddy list": "buddylist", "buddylist": "buddylist", "buddies": "buddylist", "aim": "buddylist",
        "music": "radio", "ytmusic": "ytmusic", "youtube music": "ytmusic", "spotify": "spotify",
        "finance": "finance", "bank": "finance",
        "welcome": "welcome", "settings": "settings",
        "netflix": "netflix", "hulu": "hulu", "disney": "disneyplus", "disney+": "disneyplus",
        "prime": "primevideo", "prime video": "primevideo", "youtube": "youtube",
        "hbo": "hbomax", "max": "hbomax", "hbo max": "hbomax", "peacock": "peacock",
        "apple tv": "appletv", "appletv": "appletv", "crunchyroll": "crunchyroll",
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
