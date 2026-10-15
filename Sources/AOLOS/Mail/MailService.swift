import Foundation

/// Gmail over IMAP and SMTP. One connection runs commands, a second one sits in IDLE on INBOX.
@MainActor
final class MailService {
    enum Box: Int, CaseIterable {
        case new, old, sent
    }

    let auth = GoogleAuth()
    private(set) var inbox: [MailSummary] = []
    private(set) var sent: [MailSummary] = []
    private(set) var unreadCount = 0
    private(set) var status = "Not connected"
    private(set) var isRunning = false
    private(set) var hasLoaded = false

    var onChange: (() -> Void)?
    var onNewMail: (() -> Void)?

    private var connection: IMAPConnection?
    private var idleConnection: IMAPConnection?
    private var idleTask: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private(set) var folders = MailFolders()
    private(set) var folderMessages: [String: [MailSummary]] = [:]
    private(set) var searchResults: [MailSummary] = []
    private(set) var lastSearch = ""
    private var foldersLoaded = false
    private var knownUnseen: Set<UInt32> = []

    static let inboxLimit = 300
    static let sentLimit = 100
    static let folderLimit = 150

    func summaries(for box: Box) -> [MailSummary] {
        switch box {
        case .new: return inbox.filter { !$0.seen }
        case .old: return inbox.filter { $0.seen }
        case .sent: return sent
        }
    }

    func start() {
        guard auth.isConnected, !isRunning else { return }
        isRunning = true
        setStatus("Connecting to Gmail...")
        idleTask = Task { [weak self] in await self?.idleLoop() }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refresh()
                try await self.refreshSent()
            } catch {
                self.handle(error)
            }
        }
    }

    func stop() {
        isRunning = false
        idleTask?.cancel()
        idleTask = nil
        let connections = [connection, idleConnection].compactMap { $0 }
        connection = nil
        idleConnection = nil
        Task { for c in connections { await c.close() } }
        inbox = []
        sent = []
        folderMessages = [:]
        searchResults = []
        unreadCount = 0
        knownUnseen = []
        hasLoaded = false
        foldersLoaded = false
        setStatus(auth.isConnected ? "Signed off" : "Not connected")
    }

    func refresh() async throws {
        let result = try await serial { c -> (summaries: [MailSummary], unseen: Set<UInt32>) in
            if !self.foldersLoaded {
                self.folders = try await c.specialFolders()
                self.foldersLoaded = true
            }
            try await c.select("INBOX")
            let all = try await c.uidSearch("ALL")
            let unseen = Set(try await c.uidSearch("UNSEEN"))
            let summaries = try await c.fetchSummaries(Array(all.suffix(Self.inboxLimit)))
            return (summaries, unseen)
        }
        inbox = result.summaries.sorted { $0.date > $1.date }
        unreadCount = result.unseen.count
        let arrived = result.unseen.subtracting(knownUnseen)
        let firstLoad = !hasLoaded
        knownUnseen = result.unseen
        hasLoaded = true
        setStatus(auth.email.map { "Connected as \($0)" } ?? "Connected")
        if (firstLoad && unreadCount > 0) || (!firstLoad && !arrived.isEmpty) { onNewMail?() }
    }

    func refreshSent() async throws {
        let summaries = try await serial { c -> [MailSummary] in
            try await c.select(self.folders.sent)
            let all = try await c.uidSearch("ALL")
            return try await c.fetchSummaries(Array(all.suffix(Self.sentLimit)))
        }
        sent = summaries.sorted { $0.date > $1.date }
        onChange?()
    }

    func loadFolder(_ name: String) async throws {
        let summaries = try await serial { c -> [MailSummary] in
            try await c.select(name)
            let all = try await c.uidSearch("ALL")
            return try await c.fetchSummaries(Array(all.suffix(Self.folderLimit)))
        }
        folderMessages[name] = summaries.sorted { $0.date > $1.date }
        onChange?()
    }

    /// Searches All Mail with Gmail's own query syntax through the X-GM-RAW extension.
    func search(_ query: String) async throws {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSearch = q
        guard !q.isEmpty else {
            searchResults = []
            onChange?()
            return
        }
        let folder = folders.allMail
        let summaries = try await serial { c -> [MailSummary] in
            try await c.select(folder)
            let hits = try await c.uidSearch("X-GM-RAW \(IMAPParser.quote(q))")
            return try await c.fetchSummaries(Array(hits.suffix(Self.folderLimit)))
        }
        searchResults = summaries.sorted { $0.date > $1.date }
        onChange?()
    }

    func reportSpam(_ summaries: [MailSummary]) async throws {
        try await move(summaries, to: folders.junk)
    }

    func message(_ summary: MailSummary, markSeen: Bool = true) async throws -> MailMessage {
        let mark = markSeen && !summary.seen
        let raw = try await serial { c -> Data in
            try await c.select(summary.folder)
            let raw = try await c.fetchRaw(summary.uid)
            if mark { try await c.setSeen([summary.uid], true) }
            return raw
        }
        if mark { markLocally(summary, seen: true) }
        return await Task.detached { MailMessage(summary: summary, raw: raw) }.value
    }

    func setSeen(_ summary: MailSummary, _ seen: Bool) async throws {
        try await setSeen([summary], seen)
    }

    /// Sends one STORE per folder for the whole selection.
    func setSeen(_ summaries: [MailSummary], _ seen: Bool) async throws {
        let changing = summaries.filter { $0.seen != seen }
        guard !changing.isEmpty else { return }
        for (folder, group) in Dictionary(grouping: changing, by: \.folder) {
            let uids = group.map(\.uid)
            try await serial { c in
                try await c.select(folder)
                try await c.setSeen(uids, seen)
            }
        }
        for summary in changing { markLocally(summary, seen: seen, notify: false) }
        onChange?()
    }

    func delete(_ summary: MailSummary) async throws {
        try await delete([summary])
    }

    func delete(_ summaries: [MailSummary]) async throws {
        try await move(summaries, to: folders.trash)
    }

    /// Moves the whole selection with one MOVE per source folder.
    func move(_ summaries: [MailSummary], to destination: String) async throws {
        let moving = summaries.filter { $0.folder != destination }
        guard !moving.isEmpty else { return }
        for (folder, group) in Dictionary(grouping: moving, by: \.folder) {
            let uids = group.map(\.uid)
            try await serial { c in
                try await c.select(folder)
                try await c.move(uids, to: destination)
            }
        }
        let keys = Set(moving.map { "\($0.folder)/\($0.uid)" })
        let gone: (MailSummary) -> Bool = { keys.contains("\($0.folder)/\($0.uid)") }
        inbox.removeAll(where: gone)
        sent.removeAll(where: gone)
        searchResults.removeAll(where: gone)
        for key in folderMessages.keys { folderMessages[key]?.removeAll(where: gone) }
        folderMessages[destination] = nil
        for summary in moving where summary.folder == "INBOX" && knownUnseen.remove(summary.uid) != nil {
            unreadCount = max(0, unreadCount - 1)
        }
        onChange?()
    }

    func send(_ mail: OutgoingMail) async throws {
        guard let email = auth.email else { throw MailError.notConnected }
        let token = try await auth.token()
        try await SMTPClient.send(mail, email: email, token: token)
        Task { [weak self] in try? await self?.refreshSent() }
    }

    private func markLocally(_ summary: MailSummary, seen: Bool, notify: Bool = true) {
        let same: (MailSummary) -> Bool = { $0.uid == summary.uid && $0.folder == summary.folder }
        if let i = inbox.firstIndex(where: same) { inbox[i].seen = seen }
        if let i = searchResults.firstIndex(where: same) { searchResults[i].seen = seen }
        if let i = folderMessages[summary.folder]?.firstIndex(where: same) { folderMessages[summary.folder]?[i].seen = seen }
        if summary.folder == "INBOX" {
            if seen, knownUnseen.remove(summary.uid) != nil { unreadCount = max(0, unreadCount - 1) }
            if !seen, knownUnseen.insert(summary.uid).inserted { unreadCount += 1 }
        }
        if notify { onChange?() }
    }

    private func setStatus(_ text: String) {
        status = text
        onChange?()
    }

    private func handle(_ error: Error) {
        if case MailError.auth(let reason) = error {
            isRunning = false
            idleTask?.cancel()
            setStatus(reason)
        } else {
            setStatus("Mail error: \(error.localizedDescription)")
        }
    }

    /// Runs IMAP work one operation at a time on the command connection, reconnecting once on failure.
    private func serial<T: Sendable>(_ operation: @escaping @MainActor (IMAPConnection) async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            _ = await previous?.value
            var lastError: Error = MailError.notConnected
            for _ in 0..<2 {
                do {
                    let c = try await self.commandConnection()
                    do {
                        return try await operation(c)
                    } catch {
                        if case MailError.commandFailed = error { throw error }
                        await c.close()
                        if self.connection === c { self.connection = nil }
                        throw error
                    }
                } catch {
                    lastError = error
                    if case MailError.commandFailed = error { throw error }
                    if case MailError.auth = error { throw error }
                }
            }
            throw lastError
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func commandConnection() async throws -> IMAPConnection {
        if let connection { return connection }
        let c = try await openConnection()
        connection = c
        return c
    }

    private func openConnection() async throws -> IMAPConnection {
        let token = try await auth.token()
        guard let email = auth.email else { throw MailError.notConnected }
        let c = IMAPConnection()
        try await c.open()
        try await c.authenticate(email: email, token: token)
        return c
    }

    private func idleLoop() async {
        var delay: UInt64 = 2
        while isRunning, !Task.isCancelled {
            do {
                let c = try await openConnection()
                idleConnection = c
                try await c.select("INBOX")
                delay = 2
                while isRunning, !Task.isCancelled {
                    // RFC 3501 section 5.4 lets servers drop a client idle for 30 minutes, so IDLE is renewed sooner.
                    if try await c.idle(timeout: 20 * 60) {
                        try? await refresh()
                    }
                }
            } catch {
                guard isRunning else { return }
                if let c = idleConnection { await c.close() }
                idleConnection = nil
                if case MailError.auth = error {
                    handle(error)
                    return
                }
                setStatus("Reconnecting to Gmail...")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 120)
            }
        }
    }
}
