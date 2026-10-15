import Foundation

enum MailAddress {
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuote = false
        var angle = 0
        for ch in s {
            if ch == "\"" { inQuote.toggle() }
            if ch == "<" { angle += 1 }
            if ch == ">" { angle = max(0, angle - 1) }
            if (ch == "," || ch == ";"), !inQuote, angle == 0 {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    static func email(_ s: String) -> String {
        if let l = s.lastIndex(of: "<"), let r = s.lastIndex(of: ">"), l < r {
            return s[s.index(after: l)..<r].trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func name(_ s: String) -> String {
        if let l = s.lastIndex(of: "<") {
            let n = s[..<l].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            if !n.isEmpty { return n }
        }
        return email(s)
    }
}

enum MailDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let headerFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
    ].map(formatter)
    private static let internalFormat = formatter("d-MMM-yyyy HH:mm:ss Z")
    private static let rfc2822Format = formatter("EEE, dd MMM yyyy HH:mm:ss Z")
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
    private static let shortFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()
    private static let longFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    static func parse(_ value: String?) -> Date? {
        guard var s = value else { return nil }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for f in headerFormats {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func parseInternal(_ value: String?) -> Date? {
        value.flatMap { internalFormat.date(from: $0.trimmingCharacters(in: .whitespaces)) }
    }

    static func display(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormat.string(from: date) : shortFormat.string(from: date)
    }

    static func long(_ date: Date) -> String { longFormat.string(from: date) }
    static func rfc2822(_ date: Date) -> String { rfc2822Format.string(from: date) }
}

struct MailMessage {
    let summary: MailSummary
    let headers: MIMEHeaders
    let subject: String
    let from: String
    let replyTo: String?
    let to: String
    let cc: String
    let date: String
    let messageID: String?
    let references: String?
    let html: String
    let plainText: String
    let attachments: [String]
    let hasRemoteContent: Bool

    init(summary: MailSummary, raw: Data) {
        let root = MIMEPart(raw)
        self.summary = summary
        headers = root.headers
        subject = root.headers.decoded("subject") ?? summary.subject
        from = root.headers.decoded("from") ?? summary.from
        replyTo = root.headers.decoded("reply-to")
        to = root.headers.decoded("to") ?? ""
        cc = root.headers.decoded("cc") ?? ""
        date = MailDate.parse(root.headers["date"]).map(MailDate.long) ?? MailDate.long(summary.date)
        messageID = root.headers["message-id"]
        references = root.headers["references"]

        var html: String?
        var text: String?
        var inline: [String: (type: String, data: Data)] = [:]
        var attachments: [String] = []
        Self.collect(root, html: &html, text: &text, inline: &inline, attachments: &attachments)

        var body = html ?? "<pre class=\"aolos\">\(Self.escape(text ?? ""))</pre>"
        for (cid, part) in inline {
            body = body.replacingOccurrences(of: "cid:\(cid)", with: "data:\(part.type);base64,\(part.data.base64EncodedString())")
        }
        self.html = Self.styleBlock + body
        plainText = text ?? Self.stripTags(html ?? "")
        self.attachments = attachments
        hasRemoteContent = body.contains(#/(?i)(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?\s*https?:/#)
    }

    private static let styleBlock = """
    <meta charset="utf-8"><meta name="color-scheme" content="light">\
    <style>body{font:13px Tahoma,Verdana,sans-serif;color:#111;margin:12px;overflow-wrap:anywhere}\
    img{max-width:100%;height:auto}pre.aolos{white-space:pre-wrap;font:13px Tahoma,Verdana,sans-serif;margin:0}</style>
    """

    private static func collect(_ part: MIMEPart, html: inout String?, text: inout String?,
                                inline: inout [String: (type: String, data: Data)], attachments: inout [String]) {
        if !part.children.isEmpty {
            for child in part.children {
                collect(child, html: &html, text: &text, inline: &inline, attachments: &attachments)
            }
            return
        }
        let isText = part.contentType == "text/html" || part.contentType == "text/plain"
        if let cid = part.contentID, !isText {
            inline[cid] = (part.contentType, part.decoded)
        } else if part.disposition == "attachment" || (!isText && part.filename != nil) {
            attachments.append(part.filename ?? part.contentType)
        } else if part.contentType == "text/html", html == nil {
            html = part.text
        } else if part.contentType == "text/plain", text == nil {
            text = part.text
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func stripTags(_ html: String) -> String {
        var s = html.replacing(#/(?is)<style\b.*?</style>/#, with: "")
        s = s.replacing(#/(?is)<script\b.*?</script>/#, with: "")
        s = s.replacing(#/(?i)<br\s*/?>|</p>|</div>|</tr>/#, with: "\n")
        s = s.replacing(#/<[^>]+>/#, with: "")
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacing(#/\n{3,}/#, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MailAttachment: Equatable {
    let filename: String
    let mimeType: String
    let data: Data
}

struct OutgoingMail {
    var from: String
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: String?
    var html: String? = nil
    var attachments: [MailAttachment] = []
    var returnReceipt = false

    var recipients: [String] {
        (to + cc).map(MailAddress.email).filter { !$0.isEmpty }
    }

    /// Plain text alone, text and HTML as multipart/alternative, and attachments wrapped in multipart/mixed.
    func rfc822(date: Date = Date()) -> Data {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "From: \(clean(from))",
            "To: \(clean(to.joined(separator: ", ")))",
        ]
        if !cc.isEmpty { lines.append("Cc: \(clean(cc.joined(separator: ", ")))") }
        lines.append("Subject: \(Self.encodeHeader(clean(subject)))")
        lines.append("Date: \(MailDate.rfc2822(date))")
        lines.append("Message-ID: <\(UUID().uuidString)@aol-os.local>")
        if let inReplyTo { lines.append("In-Reply-To: \(clean(inReplyTo))") }
        if let references { lines.append("References: \(clean(references))") }
        if returnReceipt { lines.append("Disposition-Notification-To: \(clean(from))") }
        lines.append("MIME-Version: 1.0")

        let text = Self.part(["Content-Type: text/plain; charset=UTF-8"], Data(Self.crlf(body).utf8))
        var content = text
        if let html {
            let htmlPart = Self.part(["Content-Type: text/html; charset=UTF-8"], Data(Self.crlf(html).utf8))
            content = Self.multipart("alternative", [text, htmlPart])
        }
        if !attachments.isEmpty {
            let files = attachments.map { a in
                Self.part([
                    "Content-Type: \(a.mimeType); name=\(Self.quotedParam(a.filename))",
                    "Content-Disposition: attachment; filename=\(Self.quotedParam(a.filename))",
                ], a.data)
            }
            content = Self.multipart("mixed", [content] + files)
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n" + content + "\r\n").utf8)
    }

    static func encodeHeader(_ s: String) -> String {
        s.allSatisfy(\.isASCII) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    private static func crlf(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func quotedParam(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return "\"\(encodeHeader(safe))\""
    }

    /// A leaf part: its headers, a blank line, then the body in base64.
    private static func part(_ headers: [String], _ data: Data) -> String {
        let encoded = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return (headers + ["Content-Transfer-Encoding: base64"]).joined(separator: "\r\n") + "\r\n\r\n" + encoded
    }

    private static func multipart(_ subtype: String, _ parts: [String]) -> String {
        let boundary = "aolos-\(UUID().uuidString)"
        var out = "Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\r\n\r\n"
        for p in parts { out += "--\(boundary)\r\n\(p)\r\n" }
        return out + "--\(boundary)--"
    }
}
