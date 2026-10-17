import AppKit
import CryptoKit
import Network

/// Receives the OAuth redirect on 127.0.0.1. Google allows any loopback port for desktop clients.
/// All state is read and written on the main queue.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?

    /// Pass a port when the provider requires the registered redirect to name one.
    init(port: UInt16? = nil) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        let listener = self.listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(MailError.timeout))
            }
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(MailError.closed))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let query = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            var params: [String: String] = [:]
            for item in query { params[item.name] = item.value ?? "" }

            let isCallback = params["code"] != nil || params["error"] != nil
            let body = isCallback
                ? "<html><body style=\"font:15px Tahoma,sans-serif;padding:40px\"><h2>You are signed on.</h2>"
                    + "<p>Return to AOL-OS. You can close this tab.</p></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\n"
                + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback { self?.finish(.success(params)) }
        }
    }
}

/// Keychain keys for the Google accounts. Pure so the migration can be tested without a keychain.
enum GoogleAccountKeys {
    static let clientID = "google.clientID"
    static let clientSecret = "google.clientSecret"
    static let accounts = "google.accounts"
    /// The single-account keys from before multiple accounts.
    static let legacyRefreshToken = "google.refreshToken"
    static let legacyEmail = "google.email"

    static func refreshToken(_ email: String) -> String { "google.refreshToken.\(email.lowercased())" }

    static func decodeList(_ value: String?) -> [String] {
        guard let data = value?.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func encodeList(_ list: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// Returns the changes that move a single-account store to the account list, or nil when nothing needs moving.
    /// A nil value in the result removes that key.
    static func migration(_ store: [String: String]) -> [String: String?]? {
        guard store[accounts] == nil, let email = store[legacyEmail] else { return nil }
        var changes: [String: String?] = [legacyEmail: nil, legacyRefreshToken: nil]
        if let token = store[legacyRefreshToken] {
            changes[refreshToken(email)] = token
            changes[accounts] = encodeList([email])
        }
        return changes
    }
}

/// The shared Google OAuth client and the list of signed-in Gmail accounts. The first account is the primary one.
@MainActor
enum GoogleAccounts {
    static let scopes = "https://mail.google.com/ openid email"
    private static var server: LoopbackServer?
    private static var migrated = false

    /// A client saved in Settings wins over the built-in one.
    static var overrideClientID: String? { Keychain.secret(GoogleAccountKeys.clientID) }
    static var hasOverrideSecret: Bool { Keychain.secret(GoogleAccountKeys.clientSecret) != nil }
    static var clientID: String? { overrideClientID ?? (GoogleClient.isConfigured ? GoogleClient.id : nil) }
    static var clientSecret: String? {
        overrideClientID != nil ? Keychain.secret(GoogleAccountKeys.clientSecret) : (GoogleClient.isConfigured ? GoogleClient.secret : nil)
    }
    static var hasClient: Bool { clientID != nil && clientSecret != nil }

    /// An empty ID clears the override and returns to the built-in client.
    static func setClient(id: String, secret: String?) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.setSecret(GoogleAccountKeys.clientID, trimmed.isEmpty ? nil : trimmed)
        if trimmed.isEmpty {
            Keychain.setSecret(GoogleAccountKeys.clientSecret, nil)
        } else if let secret, !secret.isEmpty {
            Keychain.setSecret(GoogleAccountKeys.clientSecret, secret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Signed-in addresses in order, primary first.
    static var emails: [String] {
        migrateIfNeeded()
        return GoogleAccountKeys.decodeList(Keychain.secret(GoogleAccountKeys.accounts))
    }

    private static func setEmails(_ list: [String]) {
        Keychain.setSecret(GoogleAccountKeys.accounts, list.isEmpty ? nil : GoogleAccountKeys.encodeList(list))
    }

    private static func migrateIfNeeded() {
        guard !migrated else { return }
        migrated = true
        var store: [String: String] = [:]
        for key in [GoogleAccountKeys.accounts, GoogleAccountKeys.legacyEmail, GoogleAccountKeys.legacyRefreshToken] {
            store[key] = Keychain.secret(key)
        }
        guard let changes = GoogleAccountKeys.migration(store) else { return }
        // Write the new keys before removing the old ones.
        for (key, value) in changes where value != nil { Keychain.setSecret(key, value) }
        for (key, value) in changes where value == nil { Keychain.setSecret(key, nil) }
    }

    static func makePrimary(_ email: String) {
        var list = emails
        guard let i = list.firstIndex(where: { $0.caseInsensitiveCompare(email) == .orderedSame }), i > 0 else { return }
        list.insert(list.remove(at: i), at: 0)
        setEmails(list)
    }

    /// Revokes the account's refresh token and forgets it.
    static func remove(_ email: String) {
        let key = GoogleAccountKeys.refreshToken(email)
        if let refresh = Keychain.secret(key) {
            Task { _ = try? await OAuthHTTP.postForm("https://oauth2.googleapis.com/revoke", ["token": refresh]) }
        }
        Keychain.setSecret(key, nil)
        setEmails(emails.filter { $0.caseInsensitiveCompare(email) != .orderedSame })
    }

    /// Runs the browser sign in with PKCE, saves the account, and returns its address.
    /// Google shows its account chooser, so the same flow adds a new account or reconnects one.
    static func signIn(hint: String? = nil) async throws -> String {
        guard let clientID, let secret = clientSecret else {
            throw MailError.auth("This build has no Google OAuth client. Add one in Settings.")
        }
        server?.stop()
        let server = try LoopbackServer()
        self.server = server
        defer {
            server.stop()
            if self.server === server { self.server = nil }
        }

        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = GoogleAuth.randomURLSafe(32)
        let state = GoogleAuth.randomURLSafe(16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: GoogleAuth.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        if let hint { components.queryItems?.append(URLQueryItem(name: "login_hint", value: hint)) }
        DefaultBrowser.openElsewhere(components.url!)

        let params = try await server.waitForCallback()
        NSApp.activate()
        if let error = params["error"] { throw MailError.auth("Google sign in failed: \(error)") }
        guard params["state"] == state, let code = params["code"] else {
            throw MailError.auth("Google sign in returned an unexpected response.")
        }

        let json = try await OAuthHTTP.postForm("https://oauth2.googleapis.com/token", [
            "code": code,
            "client_id": clientID,
            "client_secret": secret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String,
              let idToken = json["id_token"] as? String,
              let email = GoogleAuth.email(fromIDToken: idToken) else {
            throw MailError.auth("Google did not return a refresh token.")
        }
        Keychain.setSecret(GoogleAccountKeys.refreshToken(email), refresh)
        var list = emails
        if let i = list.firstIndex(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            list[i] = email
        } else {
            list.append(email)
        }
        setEmails(list)
        return email
    }
}

/// Access tokens for one Gmail account. The refresh token lives in the login keychain.
@MainActor
final class GoogleAuth {
    let email: String
    private var accessToken: String?
    private var expiry = Date.distantPast

    init(email: String) {
        self.email = email
    }

    var isConnected: Bool { Keychain.secret(GoogleAccountKeys.refreshToken(email)) != nil }

    /// Drops the cached access token, for example after the account signs in again.
    func reset() {
        accessToken = nil
        expiry = .distantPast
    }

    func token() async throws -> String {
        if let accessToken, expiry.timeIntervalSinceNow > 60 { return accessToken }
        let key = GoogleAccountKeys.refreshToken(email)
        guard let clientID = GoogleAccounts.clientID, let secret = GoogleAccounts.clientSecret,
              let refresh = Keychain.secret(key) else { throw MailError.notConnected }
        do {
            let json = try await OAuthHTTP.postForm("https://oauth2.googleapis.com/token", [
                "client_id": clientID,
                "client_secret": secret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            accessToken = json["access_token"] as? String
            expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        } catch MailError.auth(let reason) where reason.contains("invalid_grant") {
            Keychain.setSecret(key, nil)
            throw MailError.auth("The sign in for \(email) expired. Reconnect it in Settings.")
        }
        guard let accessToken else { throw MailError.notConnected }
        return accessToken
    }

    nonisolated static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads the email claim. The token came straight from Google's token endpoint over TLS, so the signature is not rechecked.
    nonisolated static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

}

@MainActor
enum OAuthHTTP {
    static func postForm(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = json["error"] as? String ?? "unknown_error"
            let detail = json["error_description"] as? String ?? ""
            throw MailError.auth("The sign in service returned \(error). \(detail)")
        }
        return json
    }
}
