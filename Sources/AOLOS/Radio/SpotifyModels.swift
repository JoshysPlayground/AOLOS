import Foundation

/// The Spotify app that ships with AOL-OS. It uses PKCE, so there is no client secret. Settings can override it.
enum SpotifyClient {
    static let id = ""

    static var isConfigured: Bool { !id.isEmpty }
}

enum SpotifyError: LocalizedError {
    case notConnected
    case api(status: Int, message: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Spotify is not connected."
        case .api(_, _, let reason?) where reason == "PREMIUM_REQUIRED":
            return "Spotify Premium is required to control playback."
        case .api(_, _, let reason?) where reason == "NO_ACTIVE_DEVICE":
            return "No Spotify device is active. Use Radio Setup to pick one."
        case .api(let status, let message, _):
            return "Spotify returned \(status). \(message)"
        }
    }
}

struct SpotifyTrack: Equatable {
    let uri: String
    let name: String
    let artists: [String]
    let artistURL: URL?
    let album: String
    let albumURL: URL?
    let imageURL: URL?
    let durationMs: Int
    let trackURL: URL?

    var artistLine: String { artists.joined(separator: ", ") }

    init?(json: [String: Any]?) {
        guard let json, let uri = json["uri"] as? String, let name = json["name"] as? String else { return nil }
        self.uri = uri
        self.name = name
        let artistList = json["artists"] as? [[String: Any]] ?? []
        artists = artistList.compactMap { $0["name"] as? String }
        artistURL = Self.externalURL(artistList.first)
        let albumJSON = json["album"] as? [String: Any]
        album = albumJSON?["name"] as? String ?? ""
        albumURL = Self.externalURL(albumJSON)
        imageURL = Self.bestImage(albumJSON?["images"])
        durationMs = json["duration_ms"] as? Int ?? 0
        trackURL = Self.externalURL(json)
    }

    static func externalURL(_ json: [String: Any]?) -> URL? {
        ((json?["external_urls"] as? [String: Any])?["spotify"] as? String).flatMap(URL.init(string:))
    }

    /// Picks the image closest to 300 pixels wide, which fits the Now Playing art well.
    static func bestImage(_ images: Any?) -> URL? {
        let list = images as? [[String: Any]] ?? []
        let best = list.min { abs(($0["width"] as? Int ?? 300) - 300) < abs(($1["width"] as? Int ?? 300) - 300) }
        return (best?["url"] as? String).flatMap(URL.init(string:))
    }
}

struct SpotifyDevice: Equatable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
    let volume: Int?

    init?(json: [String: Any]?) {
        guard let json, let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        type = json["type"] as? String ?? ""
        isActive = json["is_active"] as? Bool ?? false
        volume = json["volume_percent"] as? Int
    }
}

struct PlayerState {
    let isPlaying: Bool
    let progressMs: Int
    let fetchedAt: Date
    let track: SpotifyTrack?
    let device: SpotifyDevice?
    let contextURI: String?
    let shuffle: Bool

    init?(json: [String: Any]?, fetchedAt: Date = Date()) {
        guard let json else { return nil }
        isPlaying = json["is_playing"] as? Bool ?? false
        progressMs = json["progress_ms"] as? Int ?? 0
        self.fetchedAt = fetchedAt
        track = SpotifyTrack(json: json["item"] as? [String: Any])
        device = SpotifyDevice(json: json["device"] as? [String: Any])
        contextURI = (json["context"] as? [String: Any])?["uri"] as? String
        shuffle = json["shuffle_state"] as? Bool ?? false
    }

    /// Progress now, counting time since the last poll while playing.
    func progress(at date: Date = Date()) -> Int {
        guard isPlaying else { return progressMs }
        let elapsed = Int(date.timeIntervalSince(fetchedAt) * 1000)
        return min(progressMs + elapsed, track?.durationMs ?? Int.max)
    }

    static func clock(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// Something the radio can play. A context plays as a whole. A track list plays from `startIndex`.
struct RadioStation: Codable, Equatable {
    var title: String
    var subtitle: String
    var contextURI: String?
    var trackURIs: [String]?
    var startIndex: Int?
    var imageURL: String?
    var webURL: String?

    static func playlist(_ json: [String: Any]) -> RadioStation? {
        guard let uri = json["uri"] as? String, let name = json["name"] as? String else { return nil }
        let owner = (json["owner"] as? [String: Any])?["display_name"] as? String
        let description = (json["description"] as? String).map(stripTags) ?? ""
        return RadioStation(title: name, subtitle: description.isEmpty ? (owner.map { "Playlist by \($0)" } ?? "Playlist") : description,
                            contextURI: uri, imageURL: SpotifyTrack.bestImage(json["images"])?.absoluteString,
                            webURL: SpotifyTrack.externalURL(json)?.absoluteString)
    }

    static func album(_ json: [String: Any]) -> RadioStation? {
        guard let uri = json["uri"] as? String, let name = json["name"] as? String else { return nil }
        let artists = (json["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return RadioStation(title: name, subtitle: "Album by \(artists.joined(separator: ", "))", contextURI: uri,
                            imageURL: SpotifyTrack.bestImage(json["images"])?.absoluteString,
                            webURL: SpotifyTrack.externalURL(json)?.absoluteString)
    }

    static func tracks(_ title: String, subtitle: String, _ tracks: [SpotifyTrack], start: Int = 0) -> RadioStation {
        RadioStation(title: title, subtitle: subtitle, trackURIs: tracks.map(\.uri), startIndex: start,
                     imageURL: tracks.first?.imageURL?.absoluteString)
    }

    static func stripTags(_ s: String) -> String {
        s.replacing(#/<[^>]+>/#, with: "")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
