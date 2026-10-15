import Foundation

enum SMTPClient {
    static func send(_ mail: OutgoingMail, email: String, token: String,
                     host: String = "smtp.gmail.com", port: UInt16 = 465) async throws {
        let recipients = mail.recipients
        guard !recipients.isEmpty else { throw MailError.commandFailed("Add at least one recipient.") }

        let stream = NetStream(host: host, port: port)
        try await stream.open()
        do {
            try await expect(stream, 220)
            try await stream.write("EHLO aol-os.local\r\n")
            try await expect(stream, 250)

            let sasl = Data("user=\(email)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
            try await stream.write("AUTH XOAUTH2 \(sasl)\r\n")
            let (code, text) = try await reply(stream)
            if code == 334 {
                try await stream.write("\r\n")
                _ = try? await reply(stream)
                throw MailError.auth("Gmail refused the sign in for sending mail.")
            }
            guard code == 235 else { throw MailError.auth("Gmail refused the sign in: \(text)") }

            try await stream.write("MAIL FROM:<\(email)>\r\n")
            try await expect(stream, 250)
            for r in recipients {
                try await stream.write("RCPT TO:<\(r)>\r\n")
                try await expect(stream, 250, 251)
            }
            try await stream.write("DATA\r\n")
            try await expect(stream, 354)
            try await stream.write(dotStuffed(mail.rfc822()))
            try await stream.write(".\r\n")
            try await expect(stream, 250)
            try? await stream.write("QUIT\r\n")
        } catch {
            await stream.close()
            throw error
        }
        await stream.close()
    }

    /// Lines that begin with a period get a second one, per the SMTP DATA rules.
    static func dotStuffed(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 16)
        var atLineStart = true
        for b in data {
            if atLineStart, b == UInt8(ascii: ".") { out.append(b) }
            out.append(b)
            atLineStart = b == 10
        }
        if !out.isEmpty, out.last != 10 { out.append(contentsOf: [13, 10]) }
        return out
    }

    private static func reply(_ stream: NetStream) async throws -> (Int, String) {
        var lines: [String] = []
        while true {
            let line = String(decoding: try await stream.readLine(), as: UTF8.self)
            lines.append(line)
            let chars = Array(line)
            if chars.count < 4 || chars[3] != "-" { break }
        }
        let last = lines.last ?? ""
        return (Int(last.prefix(3)) ?? 0, lines.joined(separator: " "))
    }

    private static func expect(_ stream: NetStream, _ codes: Int...) async throws {
        let (code, text) = try await reply(stream)
        guard codes.contains(code) else { throw MailError.commandFailed(text) }
    }
}
