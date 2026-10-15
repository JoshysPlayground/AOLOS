import Foundation

struct MailSummary: Hashable {
    let uid: UInt32
    let folder: String
    var seen: Bool
    let date: Date
    let from: String
    let to: String
    let subject: String
}

struct MailFolders {
    var sent = "[Gmail]/Sent Mail"
    var trash = "[Gmail]/Trash"
}

/// One authenticated IMAP session. Callers must not interleave commands. MailService serializes them.
actor IMAPConnection {
    private let stream: NetStream
    private var tagCounter = 0
    private(set) var selected: String?
    private var idleTag: String?
    private var doneSent = false

    init(host: String = "imap.gmail.com", port: UInt16 = 993) {
        stream = NetStream(host: host, port: port)
    }

    func open() async throws {
        try await stream.open()
        let greeting = try await readResponse()
        guard greeting.text.hasPrefix("* OK") else { throw MailError.protocolError(greeting.text) }
    }

    func close() async {
        await stream.close()
    }

    func authenticate(email: String, token: String) async throws {
        let sasl = Data("user=\(email)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
        do {
            try await command("AUTHENTICATE XOAUTH2 \(sasl)")
        } catch MailError.commandFailed(let reason) {
            throw MailError.auth("Gmail refused the sign in: \(reason)")
        }
    }

    func select(_ mailbox: String) async throws {
        guard selected != mailbox else { return }
        selected = nil
        try await command("SELECT \(IMAPParser.quote(mailbox))")
        selected = mailbox
    }

    func specialFolders() async throws -> MailFolders {
        var folders = MailFolders()
        for response in try await command("LIST \"\" \"*\"") {
            guard let entry = IMAPParser.listEntry(response) else { continue }
            let attrs = entry.attributes.map { $0.lowercased() }
            if attrs.contains("\\sent") { folders.sent = entry.name }
            if attrs.contains("\\trash") { folders.trash = entry.name }
        }
        return folders
    }

    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        try await command("UID SEARCH \(criteria)").compactMap(IMAPParser.searchUIDs).flatMap { $0 }.sorted()
    }

    func fetchSummaries(_ uids: [UInt32]) async throws -> [MailSummary] {
        guard !uids.isEmpty, let folder = selected else { return [] }
        let responses = try await command(
            "UID FETCH \(IMAPParser.uidSet(uids)) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)])")
        return responses.compactMap { response -> MailSummary? in
            guard let items = IMAPParser.fetchItems(response),
                  let uid = items["UID"]?.text.flatMap({ UInt32($0) }) else { return nil }
            let flags = (items["FLAGS"]?.list ?? []).compactMap { $0.text?.lowercased() }
            let header = items.first { $0.key.hasPrefix("BODY[") }?.value.data ?? Data()
            let headers = MIME.parseHeaders(header)
            let date = MailDate.parseInternal(items["INTERNALDATE"]?.text)
                ?? MailDate.parse(headers["date"]) ?? .distantPast
            return MailSummary(uid: uid, folder: folder, seen: flags.contains("\\seen"), date: date,
                               from: headers.decoded("from") ?? "", to: headers.decoded("to") ?? "",
                               subject: headers.decoded("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)")
        }
    }

    func fetchRaw(_ uid: UInt32) async throws -> Data {
        for response in try await command("UID FETCH \(uid) (UID BODY.PEEK[])") {
            if let items = IMAPParser.fetchItems(response), let data = items["BODY[]"]?.data { return data }
        }
        throw MailError.protocolError("Message \(uid) was not returned.")
    }

    func setSeen(_ uids: [UInt32], _ seen: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await command("UID STORE \(IMAPParser.uidSet(uids)) \(seen ? "+" : "-")FLAGS.SILENT (\\Seen)")
    }

    func move(_ uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await command("UID MOVE \(IMAPParser.uidSet(uids)) \(IMAPParser.quote(mailbox))")
    }

    /// Waits for mailbox changes. Returns true when the server reported new or removed messages.
    func idle(timeout: TimeInterval) async throws -> Bool {
        tagCounter += 1
        let tag = String(format: "A%04d", tagCounter)
        try await stream.write("\(tag) IDLE\r\n")
        let first = try await readResponse()
        guard first.isContinuation else { throw MailError.protocolError(first.text) }
        idleTag = tag
        doneSent = false
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.endIdle()
        }
        defer {
            timer.cancel()
            idleTag = nil
        }

        var changed = false
        while true {
            let response = try await readResponse()
            if response.text.hasPrefix(tag + " ") { return changed }
            if response.text.hasPrefix("* BYE") { throw MailError.closed }
            let upper = response.text.uppercased()
            if response.isUntagged, upper.hasSuffix(" EXISTS") || upper.hasSuffix(" EXPUNGE") || upper.contains(" FETCH ") {
                changed = true
                await endIdle()
            }
        }
    }

    func endIdle() async {
        guard idleTag != nil, !doneSent else { return }
        doneSent = true
        try? await stream.write("DONE\r\n")
    }

    @discardableResult
    private func command(_ text: String) async throws -> [IMAPResponse] {
        tagCounter += 1
        let tag = String(format: "A%04d", tagCounter)
        try await stream.write("\(tag) \(text)\r\n")
        var untagged: [IMAPResponse] = []
        while true {
            let response = try await readResponse()
            if response.text.hasPrefix(tag + " ") {
                let status = response.text.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") { return untagged }
                throw MailError.commandFailed(String(status))
            } else if response.isContinuation {
                // A continuation here is a SASL error challenge. An empty reply ends the exchange.
                try await stream.write("\r\n")
            } else {
                untagged.append(response)
            }
        }
    }

    private func readResponse() async throws -> IMAPResponse {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = String(decoding: try await stream.readLine(), as: UTF8.self)
            text += line
            guard let count = IMAPResponse.trailingLiteralLength(line) else {
                return IMAPResponse(text: text, literals: literals)
            }
            literals.append(try await stream.readBytes(count))
        }
    }
}
