import Foundation

struct SlackAPIError: LocalizedError {
    let code: String

    var errorDescription: String? {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "account_inactive":
            return "Slack rejected the token. Paste a new one in Settings."
        case "missing_scope":
            return "The Slack app is missing a scope. See docs/slack.md."
        case "not_in_channel":
            return "You are not in that Slack channel."
        case "channel_not_found":
            return "Slack could not find that conversation."
        case "ratelimited":
            return "Slack is rate limiting AOL-OS. Try again in a minute."
        default:
            return "Slack said \(code)."
        }
    }
}

/// Slack Web API calls made with a user token, so messages go out as you.
@MainActor
final class SlackAPI {
    let token: String
    static let base = URL(string: "https://slack.com/api/")!

    init(token: String) {
        self.token = token
    }

    /// Posts form encoded arguments. Arrays and objects are sent as JSON strings, which Slack accepts for every
    /// method. A 429 waits for `Retry-After` and tries again.
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.base.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(params).data(using: .utf8)
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 429, attempt < 2 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(wait, 60) * 1_000_000_000))
                continue
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SlackAPIError(code: "bad_response")
            }
            guard json["ok"] as? Bool == true else { throw SlackAPIError(code: json["error"] as? String ?? "unknown_error") }
            return json
        }
        throw SlackAPIError(code: "ratelimited")
    }

    /// Follows `response_metadata.next_cursor` and joins the `key` arrays of every page.
    func paged(_ method: String, _ params: [String: Any] = [:], key: String, maxPages: Int = 25) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var cursor = ""
        for _ in 0..<maxPages {
            var page = params
            page["limit"] = page["limit"] ?? 200
            if !cursor.isEmpty { page["cursor"] = cursor }
            let json = try await call(method, page)
            items += json[key] as? [[String: Any]] ?? []
            cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            if cursor.isEmpty { break }
        }
        return items
    }

    /// Uploads one file with `files.getUploadURLExternal` and returns its ID for `files.completeUploadExternal`.
    func uploadFile(name: String, data: Data) async throws -> String {
        let ticket = try await call("files.getUploadURLExternal", ["filename": name, "length": data.count])
        guard let string = ticket["upload_url"] as? String, let url = URL(string: string),
              let fileID = ticket["file_id"] as? String else { throw SlackAPIError(code: "bad_response") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SlackAPIError(code: "upload_failed") }
        return fileID
    }

    nonisolated static func formBody(_ params: [String: Any]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.keys.sorted().compactMap { key in
            let value: String
            switch params[key] {
            case let string as String: value = string
            case let bool as Bool: value = bool ? "true" : "false"
            case let number as NSNumber: value = number.stringValue
            case let other?:
                guard JSONSerialization.isValidJSONObject(other),
                      let data = try? JSONSerialization.data(withJSONObject: other) else { return nil }
                value = String(decoding: data, as: UTF8.self)
            case nil: return nil
            }
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            return "\(k)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// Socket Mode connection for live events. Needs an app-level token with `connections:write`.
@MainActor
final class SlackSocket {
    var onEvent: (([String: Any]) -> Void)?
    var onConnected: ((Bool) -> Void)?
    private(set) var isConnected = false
    private let appToken: String
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var retryDelay: TimeInterval = 5
    private var stopped = false

    init(appToken: String) {
        self.appToken = appToken
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        generation += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        setConnected(false)
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        onConnected?(value)
    }

    private func connect() {
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: SlackAPI.base.appendingPathComponent("apps.connections.open"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(self.appToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard json["ok"] as? Bool == true, let string = json["url"] as? String, let url = URL(string: string) else {
                    throw SlackAPIError(code: json["error"] as? String ?? "bad_response")
                }
                guard gen == self.generation, !self.stopped else { return }
                let task = URLSession.shared.webSocketTask(with: url)
                self.task = task
                task.resume()
                self.receive(task, gen)
            } catch {
                NSLog("AOL-OS: Slack Socket Mode could not connect: \(error.localizedDescription)")
                self.scheduleReconnect(gen)
            }
        }
    }

    private func scheduleReconnect(_ gen: Int) {
        guard gen == generation, !stopped else { return }
        setConnected(false)
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, !self.stopped else { return }
                self.connect()
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    switch result {
                    case .failure:
                        self.scheduleReconnect(gen)
                    case .success(let message):
                        switch message {
                        case .string(let text): self.handle(Data(text.utf8), task)
                        case .data(let data): self.handle(data, task)
                        @unknown default: break
                        }
                        if gen == self.generation { self.receive(task, gen) }
                    }
                }
            }
        }
    }

    private func handle(_ data: Data, _ task: URLSessionWebSocketTask) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let envelope = json["envelope_id"] as? String,
           let ack = try? JSONSerialization.data(withJSONObject: ["envelope_id": envelope]) {
            task.send(.string(String(decoding: ack, as: UTF8.self))) { _ in }
        }
        switch json["type"] as? String {
        case "hello":
            retryDelay = 5
            setConnected(true)
        case "disconnect":
            // Slack refreshes Socket Mode URLs every few hours and warns first. Reconnect right away.
            connect()
        case "events_api":
            if let event = (json["payload"] as? [String: Any])?["event"] as? [String: Any] { onEvent?(event) }
        default:
            break
        }
    }
}
