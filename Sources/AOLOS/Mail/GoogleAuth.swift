import AppKit
import CryptoKit
import Network

/// Receives the OAuth redirect on 127.0.0.1. Google allows any loopback port for desktop clients.
/// All state is read and written on the main queue.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
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

/// Google OAuth for IMAP and SMTP. The client ID, client secret and refresh token live in the login keychain.
@MainActor
final class GoogleAuth {
    static let scopes = "https://mail.google.com/ openid email"

    private enum Key {
        static let clientID = "google.clientID"
        static let clientSecret = "google.clientSecret"
        static let refreshToken = "google.refreshToken"
        static let email = "google.email"
    }

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var server: LoopbackServer?

    var clientID: String? { Keychain.secret(Key.clientID) }
    var hasClientSecret: Bool { Keychain.secret(Key.clientSecret) != nil }
    var hasClient: Bool { clientID != nil && hasClientSecret }
    var email: String? { Keychain.secret(Key.email) }
    var isConnected: Bool { email != nil && Keychain.secret(Key.refreshToken) != nil }

    func setClient(id: String, secret: String?) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.setSecret(Key.clientID, trimmed.isEmpty ? nil : trimmed)
        if let secret, !secret.isEmpty {
            Keychain.setSecret(Key.clientSecret, secret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Runs the browser sign in with PKCE and returns the signed-in address.
    func connect() async throws -> String {
        guard let clientID, let secret = Keychain.secret(Key.clientSecret) else {
            throw MailError.auth("Add your Google OAuth client ID and secret in Settings first.")
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
        let verifier = Self.randomURLSafe(32)
        let state = Self.randomURLSafe(16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(components.url!)

        let params = try await server.waitForCallback()
        NSApp.activate()
        if let error = params["error"] { throw MailError.auth("Google sign in failed: \(error)") }
        guard params["state"] == state, let code = params["code"] else {
            throw MailError.auth("Google sign in returned an unexpected response.")
        }

        let json = try await Self.postForm("https://oauth2.googleapis.com/token", [
            "code": code,
            "client_id": clientID,
            "client_secret": secret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String,
              let idToken = json["id_token"] as? String,
              let email = Self.email(fromIDToken: idToken) else {
            throw MailError.auth("Google did not return a refresh token.")
        }
        store(json)
        Keychain.setSecret(Key.refreshToken, refresh)
        Keychain.setSecret(Key.email, email)
        return email
    }

    func token() async throws -> String {
        if let accessToken, expiry.timeIntervalSinceNow > 60 { return accessToken }
        guard let clientID, let secret = Keychain.secret(Key.clientSecret),
              let refresh = Keychain.secret(Key.refreshToken) else { throw MailError.notConnected }
        do {
            let json = try await Self.postForm("https://oauth2.googleapis.com/token", [
                "client_id": clientID,
                "client_secret": secret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            store(json)
        } catch MailError.auth(let reason) where reason.contains("invalid_grant") {
            Keychain.setSecret(Key.refreshToken, nil)
            throw MailError.auth("Your Gmail sign in expired. Connect Gmail again in Settings.")
        }
        guard let accessToken else { throw MailError.notConnected }
        return accessToken
    }

    func disconnect() {
        if let refresh = Keychain.secret(Key.refreshToken) {
            Task { _ = try? await Self.postForm("https://oauth2.googleapis.com/revoke", ["token": refresh]) }
        }
        Keychain.setSecret(Key.refreshToken, nil)
        Keychain.setSecret(Key.email, nil)
        accessToken = nil
        expiry = .distantPast
    }

    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
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

    private static func postForm(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
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
            throw MailError.auth("Google returned \(error). \(detail)")
        }
        return json
    }
}
