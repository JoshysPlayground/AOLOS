import AppKit

/// Every signed-in Gmail account. Each account has its own MailService. The Mailbox, Write Mail and the
/// Welcome screen read the merged view from here, and actions on summaries are routed by `MailSummary.account`.
@MainActor
final class MailCenter {
    private var loaded: [MailService]?
    private(set) var lastSearch = ""

    var onChange: (() -> Void)?
    var onNewMail: (() -> Void)?

    private var wantsRunning = false
    private var lastNewMail = Date.distantPast

    init() {
        // Sockets rarely survive sleep. Reconnect and check every account once the Mac is awake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        }
    }

    private func checkAfterWake() {
        guard wantsRunning else { return }
        let services = accounts
        Task {
            // Give Wi-Fi a moment to come back.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            for s in services { await s.check(reconnect: true) }
        }
    }

    /// Read from the keychain on first use, so nothing touches the keychain before sign on.
    var accounts: [MailService] {
        if let loaded { return loaded }
        let list = GoogleAccounts.emails.map(makeService)
        loaded = list
        return list
    }

    private func makeService(_ email: String) -> MailService {
        let service = MailService(email: email)
        service.onChange = { [weak self] in self?.onChange?() }
        service.onNewMail = { [weak self] in self?.newMail() }
        return service
    }

    var primary: MailService? { accounts.first }
    var emails: [String] { accounts.map(\.email) }
    var hasClient: Bool { GoogleAccounts.hasClient }
    /// True when at least one account can sign in.
    var isConnected: Bool { accounts.contains { $0.auth.isConnected } }
    var isRunning: Bool { accounts.contains(where: \.isRunning) }
    var hasLoaded: Bool { accounts.contains(where: \.hasLoaded) }
    var unreadCount: Int { accounts.reduce(0) { $0 + $1.unreadCount } }
    var inbox: [MailSummary] { Self.merge(accounts.map(\.inbox)) }
    var sent: [MailSummary] { Self.merge(accounts.map(\.sent)) }
    /// Errors that need attention, one per account.
    var problems: [String] { accounts.compactMap(\.lastError) }
    /// Accounts in the list whose refresh token is gone, for example after it expired.
    var signedOut: [String] { accounts.filter { !$0.auth.isConnected }.map(\.email) }

    var status: String {
        if accounts.isEmpty { return "Not connected" }
        if let problem = problems.first { return problem }
        return accounts.count == 1 ? accounts[0].status : "\(accounts.count) accounts connected"
    }

    func service(_ email: String) -> MailService? {
        accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    func service(for summary: MailSummary) -> MailService? {
        service(summary.account) ?? (summary.account.isEmpty ? primary : nil)
    }

    /// Rebuilds the account list from the keychain, keeping services that are still signed in.
    func reloadAccounts() {
        let emails = GoogleAccounts.emails
        let current = accounts
        let kept = current.filter { s in emails.contains { $0.caseInsensitiveCompare(s.email) == .orderedSame } }
        for gone in current where !kept.contains(where: { $0 === gone }) { gone.stop() }
        loaded = emails.map { email in
            kept.first { $0.email.caseInsensitiveCompare(email) == .orderedSame } ?? makeService(email)
        }
        if wantsRunning { accounts.forEach { $0.start() } }
        onChange?()
    }

    /// Several accounts finish their first load together at sign on. One sound covers them.
    private func newMail() {
        guard Date().timeIntervalSince(lastNewMail) > 3 else { return }
        lastNewMail = Date()
        onNewMail?()
    }

    func start() {
        wantsRunning = true
        accounts.forEach { $0.start() }
    }

    func stop() {
        wantsRunning = false
        accounts.forEach { $0.stop() }
        lastSearch = ""
    }

    /// Restarts one account after it signs in again.
    func restart(_ email: String) {
        guard let s = service(email) else { return }
        s.stop()
        s.auth.reset()
        if wantsRunning { s.start() }
    }

    /// Checks every account (or one) now. Errors from each account are collected so one bad account does not hide the rest.
    func refresh(account: String? = nil) async throws {
        start()
        var firstError: Error?
        for s in targets(account) where s.auth.isConnected {
            do {
                try await s.refresh()
                try await s.refreshSent()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    func summaries(for box: MailService.Box, account: String? = nil) -> [MailSummary] {
        Self.merge(targets(account).map { $0.summaries(for: box) })
    }

    func searchResults(account: String? = nil) -> [MailSummary] {
        Self.merge(targets(account).filter { $0.lastSearch == lastSearch }.map(\.searchResults))
    }

    /// Searches each account with Gmail's own query syntax and merges the hits.
    func search(_ query: String, account: String? = nil) async throws {
        lastSearch = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstError: Error?
        for s in targets(account) where s.auth.isConnected {
            do { try await s.search(query) } catch { firstError = firstError ?? error }
        }
        onChange?()
        if let firstError { throw firstError }
    }

    func message(_ summary: MailSummary, markSeen: Bool = true) async throws -> MailMessage {
        try await owner(summary).message(summary, markSeen: markSeen)
    }

    func setSeen(_ summaries: [MailSummary], _ seen: Bool) async throws {
        for (s, group) in try grouped(summaries) { try await s.setSeen(group, seen) }
    }

    func delete(_ summaries: [MailSummary]) async throws {
        for (s, group) in try grouped(summaries) { try await s.delete(group) }
    }

    func reportSpam(_ summaries: [MailSummary]) async throws {
        for (s, group) in try grouped(summaries) { try await s.reportSpam(group) }
    }

    func send(_ mail: OutgoingMail, from email: String) async throws {
        guard let s = service(email) else { throw MailError.notConnected }
        try await s.send(mail)
    }

    private func targets(_ account: String?) -> [MailService] {
        guard let account else { return accounts }
        return service(account).map { [$0] } ?? []
    }

    private func owner(_ summary: MailSummary) throws -> MailService {
        guard let s = service(for: summary) else { throw MailError.notConnected }
        return s
    }

    private func grouped(_ summaries: [MailSummary]) throws -> [(MailService, [MailSummary])] {
        var out: [(MailService, [MailSummary])] = []
        for summary in summaries {
            let s = try owner(summary)
            if let i = out.firstIndex(where: { $0.0 === s }) { out[i].1.append(summary) } else { out.append((s, [summary])) }
        }
        return out
    }

    // MARK: - Pure helpers

    /// Newest first across accounts.
    nonisolated static func merge(_ lists: [[MailSummary]]) -> [MailSummary] {
        lists.count == 1 ? lists[0] : lists.flatMap { $0 }.sorted { $0.date > $1.date }
    }

    /// The account a reply goes out from: the account that received the message, else one of ours named in To or Cc,
    /// else the primary account.
    nonisolated static func replyAccount(account: String, to: String, cc: String, accounts: [String]) -> String? {
        if let match = accounts.first(where: { $0.caseInsensitiveCompare(account) == .orderedSame }) { return match }
        let named = Set((MailAddress.split(to) + MailAddress.split(cc)).map { MailAddress.email($0).lowercased() })
        return accounts.first { named.contains($0.lowercased()) } ?? accounts.first
    }

    nonisolated static let badgeColors: [(Int, Int, Int)] = [
        (43, 98, 196), (230, 120, 0), (20, 140, 70), (130, 50, 170), (200, 40, 40), (0, 140, 150),
    ]

    func badgeColor(_ email: String) -> NSColor {
        let i = accounts.firstIndex { $0.email.caseInsensitiveCompare(email) == .orderedSame } ?? 0
        let c = Self.badgeColors[i % Self.badgeColors.count]
        return Theme.rgb(c.0, c.1, c.2)
    }
}
