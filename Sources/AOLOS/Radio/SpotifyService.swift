import AppKit

/// Spotify sign in with PKCE over the loopback redirect. Spotify accepts a runtime port on 127.0.0.1.
@MainActor
final class SpotifyAuth {
    static let scopes = [
        "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing",
        "playlist-read-private", "playlist-read-collaborative", "user-library-read", "user-library-modify",
        "user-read-recently-played",
    ].joined(separator: " ")

    private enum Key {
        static let clientID = "spotify.clientID"
        static let refreshToken = "spotify.refreshToken"
        static let user = "spotify.user"
    }

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var server: LoopbackServer?

    var overrideClientID: String? { Keychain.secret(Key.clientID) }
    var clientID: String? { overrideClientID ?? (SpotifyClient.isConfigured ? SpotifyClient.id : nil) }
    var isConnected: Bool { Keychain.secret(Key.refreshToken) != nil }
    var userName: String? {
        get { Keychain.secret(Key.user) }
        set { Keychain.setSecret(Key.user, newValue) }
    }

    func setClientID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.setSecret(Key.clientID, trimmed.isEmpty ? nil : trimmed)
    }

    func connect() async throws {
        guard let clientID else { throw SpotifyError.notConnected }
        server?.stop()
        let server = try LoopbackServer()
        self.server = server
        defer {
            server.stop()
            if self.server === server { self.server = nil }
        }

        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        let verifier = GoogleAuth.randomURLSafe(48)
        let state = GoogleAuth.randomURLSafe(16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: GoogleAuth.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)

        let params = try await server.waitForCallback()
        NSApp.activate()
        if let error = params["error"] { throw MailError.auth("Spotify sign in failed: \(error)") }
        guard params["state"] == state, let code = params["code"] else {
            throw MailError.auth("Spotify sign in returned an unexpected response.")
        }
        let json = try await OAuthHTTP.postForm("https://accounts.spotify.com/api/token", [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        store(json)
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, expiry.timeIntervalSinceNow > 60 { return accessToken }
        guard let clientID, let refresh = Keychain.secret(Key.refreshToken) else { throw SpotifyError.notConnected }
        do {
            store(try await OAuthHTTP.postForm("https://accounts.spotify.com/api/token", [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": clientID,
            ]))
        } catch MailError.auth(let reason) where reason.contains("invalid_grant") {
            disconnect()
            throw SpotifyError.notConnected
        }
        guard let accessToken else { throw SpotifyError.notConnected }
        return accessToken
    }

    func disconnect() {
        Keychain.setSecret(Key.refreshToken, nil)
        Keychain.setSecret(Key.user, nil)
        accessToken = nil
        expiry = .distantPast
    }

    /// Spotify may rotate the refresh token on every refresh, so a new one replaces the stored one.
    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if let refresh = json["refresh_token"] as? String { Keychain.setSecret(Key.refreshToken, refresh) }
    }
}

@MainActor
final class SpotifyService {
    enum Category: String, CaseIterable {
        case presets = "My Presets"
        case playlists = "My Playlists"
        case liked = "Liked Songs"
        case albums = "Saved Albums"
        case recent = "Recently Played"
        case search = "Search Results"
    }

    let auth = SpotifyAuth()
    private(set) var player: PlayerState?
    private(set) var devices: [SpotifyDevice] = []
    private(set) var queue: [SpotifyTrack] = []
    private(set) var stations: [Category: [RadioStation]] = [:]
    private(set) var status = ""
    var onChange: (() -> Void)?

    private var pollTimer: Timer?
    private var lastQueueTrack: String?
    static let spotifyAppID = "com.spotify.client"

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func poll() {
        guard auth.isConnected else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let json = try await self.call("GET", "/me/player") as? [String: Any]
                self.player = PlayerState(json: json)
                if self.player?.track?.uri != self.lastQueueTrack {
                    self.lastQueueTrack = self.player?.track?.uri
                    try? await self.loadQueue()
                }
                self.status = self.player?.device.map { "Playing on \($0.name)" } ?? "No active Spotify device"
            } catch {
                self.status = error.localizedDescription
            }
            self.onChange?()
        }
    }

    func loadLibrary() async {
        do {
            if auth.userName == nil, let me = try await call("GET", "/me") as? [String: Any] {
                auth.userName = me["display_name"] as? String ?? me["id"] as? String
            }
            let playlists = try await call("GET", "/me/playlists", query: ["limit": "50"]) as? [String: Any]
            stations[.playlists] = (playlists?["items"] as? [[String: Any]] ?? []).compactMap(RadioStation.playlist)

            let albums = try await call("GET", "/me/albums", query: ["limit": "50"]) as? [String: Any]
            stations[.albums] = (albums?["items"] as? [[String: Any]] ?? [])
                .compactMap { ($0["album"] as? [String: Any]).flatMap(RadioStation.album) }

            let liked = try await call("GET", "/me/tracks", query: ["limit": "50"]) as? [String: Any]
            let likedTracks = (liked?["items"] as? [[String: Any]] ?? []).compactMap { SpotifyTrack(json: $0["track"] as? [String: Any]) }
            stations[.liked] = likedTracks.isEmpty ? [] : [RadioStation.tracks("Liked Songs", subtitle: "Your 50 most recent likes", likedTracks)]

            let recent = try await call("GET", "/me/player/recently-played", query: ["limit": "30"]) as? [String: Any]
            var seen = Set<String>()
            let recentTracks = (recent?["items"] as? [[String: Any]] ?? [])
                .compactMap { SpotifyTrack(json: $0["track"] as? [String: Any]) }
                .filter { seen.insert($0.uri).inserted }
            stations[.recent] = recentTracks.enumerated().map { i, t in
                RadioStation.tracks(t.name, subtitle: t.artistLine, recentTracks, start: i)
            }
        } catch {
            status = error.localizedDescription
        }
        onChange?()
    }

    func setPresets(_ presets: [RadioStation]) {
        stations[.presets] = presets
        onChange?()
    }

    func search(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        do {
            let json = try await call("GET", "/search", query: ["q": q, "type": "track,playlist,album", "limit": "10"]) as? [String: Any]
            let tracks = ((json?["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap { SpotifyTrack(json: $0) }
            var results = tracks.enumerated().map { i, t in RadioStation.tracks(t.name, subtitle: t.artistLine, tracks, start: i) }
            results += ((json?["playlists"] as? [String: Any])?["items"] as? [Any] ?? [])
                .compactMap { ($0 as? [String: Any]).flatMap(RadioStation.playlist) }
            results += ((json?["albums"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap(RadioStation.album)
            stations[.search] = results
        } catch {
            status = error.localizedDescription
        }
        onChange?()
    }

    func play(_ station: RadioStation) async throws {
        let device = try await ensureDevice()
        var body: [String: Any] = [:]
        if let context = station.contextURI {
            body["context_uri"] = context
        } else if let uris = station.trackURIs {
            body["uris"] = Array(uris.prefix(100))
            body["offset"] = ["position": station.startIndex ?? 0]
        }
        try await call("PUT", "/me/player/play", query: ["device_id": device], body: body)
        refreshSoon()
    }

    func togglePlay() async throws {
        if player?.isPlaying == true {
            try await call("PUT", "/me/player/pause")
        } else {
            let device = try await ensureDevice()
            try await call("PUT", "/me/player/play", query: ["device_id": device])
        }
        refreshSoon()
    }

    func stop() async throws {
        if player?.isPlaying == true { try await call("PUT", "/me/player/pause") }
        _ = try? await call("PUT", "/me/player/seek", query: ["position_ms": "0"])
        refreshSoon()
    }

    func next() async throws {
        try await call("POST", "/me/player/next")
        refreshSoon()
    }

    func previous() async throws {
        try await call("POST", "/me/player/previous")
        refreshSoon()
    }

    func setVolume(_ percent: Int) async throws {
        try await call("PUT", "/me/player/volume", query: ["volume_percent": "\(max(0, min(100, percent)))"])
    }

    func like(_ track: SpotifyTrack) async throws {
        try await call("PUT", "/me/library", query: ["uris": track.uri])
    }

    func loadDevices() async throws {
        let json = try await call("GET", "/me/player/devices") as? [String: Any]
        devices = (json?["devices"] as? [[String: Any]] ?? []).compactMap { SpotifyDevice(json: $0) }
        onChange?()
    }

    func transfer(to device: SpotifyDevice) async throws {
        try await call("PUT", "/me/player", body: ["device_ids": [device.id], "play": player?.isPlaying ?? false])
        refreshSoon()
    }

    var spotifyAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.spotifyAppID) }

    /// Starts the Spotify desktop app hidden so it can act as the speaker for the radio.
    func launchSpotifyApp() async {
        guard let url = spotifyAppURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Returns a device to play on, preferring the active one, then this Mac's Spotify app.
    private func ensureDevice() async throws -> String {
        if let active = player?.device { return active.id }
        try await loadDevices()
        if let active = devices.first(where: \.isActive) ?? devices.first(where: { $0.type == "Computer" }) ?? devices.first {
            return active.id
        }
        guard spotifyAppURL != nil else {
            throw SpotifyError.api(status: 404, message: "", reason: "NO_ACTIVE_DEVICE")
        }
        status = "Starting Spotify on this Mac..."
        onChange?()
        await launchSpotifyApp()
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await loadDevices()
            if let device = devices.first(where: { $0.type == "Computer" }) ?? devices.first { return device.id }
        }
        throw SpotifyError.api(status: 404, message: "", reason: "NO_ACTIVE_DEVICE")
    }

    private func loadQueue() async throws {
        let json = try await call("GET", "/me/player/queue") as? [String: Any]
        queue = (json?["queue"] as? [[String: Any]] ?? []).compactMap { SpotifyTrack(json: $0) }
    }

    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.poll()
        }
    }

    @discardableResult
    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any? {
        for attempt in 0..<2 {
            var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
            if !query.isEmpty {
                components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(try await auth.token(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if method != "GET" {
                request.httpBody = Data()
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
            guard (200..<300).contains(status) else {
                let error = (json as? [String: Any])?["error"] as? [String: Any]
                throw SpotifyError.api(status: status, message: error?["message"] as? String ?? "",
                                       reason: error?["reason"] as? String)
            }
            return status == 204 ? nil : json
        }
        throw SpotifyError.notConnected
    }
}
