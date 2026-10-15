import Foundation

struct MIMEHeaders {
    private(set) var fields: [(name: String, value: String)]

    init(_ fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func decoded(_ name: String) -> String? {
        self[name].map(MIME.decodeWords)
    }
}

enum MIME {
    static func split(_ data: Data) -> (header: Data, body: Data) {
        let data = Data(data)
        if data.starts(with: [13, 10]) { return (Data(), Data(data.dropFirst(2))) }
        if data.starts(with: [10]) { return (Data(), Data(data.dropFirst(1))) }
        let crlf = data.range(of: Data([13, 10, 13, 10]))
        let lf = data.range(of: Data([10, 10]))
        if let r = [crlf, lf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
            return (Data(data[..<r.lowerBound]), Data(data[r.upperBound...]))
        }
        return (data, Data())
    }

    static func parseHeaders(_ data: Data) -> MIMEHeaders {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var fields: [(name: String, value: String)] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                if !fields.isEmpty {
                    fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields.append((name: line[..<colon].trimmingCharacters(in: .whitespaces),
                           value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return MIMEHeaders(fields)
    }

    /// Decodes RFC 2047 encoded words. Whitespace between adjacent encoded words is dropped.
    static func decodeWords(_ s: String) -> String {
        let pattern = #/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/#
        var result = ""
        var rest = s[...]
        var lastWasEncoded = false
        while let m = rest.firstMatch(of: pattern) {
            let between = rest[rest.startIndex..<m.range.lowerBound]
            if !(lastWasEncoded && between.allSatisfy(\.isWhitespace)) { result += between }
            let raw = Data(m.3.utf8)
            let bytes = m.2.lowercased() == "b" ? base64(raw) : quotedPrintable(raw, underscoreIsSpace: true)
            result += string(bytes, charset: String(m.1))
            lastWasEncoded = true
            rest = rest[m.range.upperBound...]
        }
        return result + rest
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        let b = [UInt8](data)
        var out = Data()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "=") {
                if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { i += 3; continue }
                if i + 2 < b.count, let hi = hex(b[i + 1]), let lo = hex(b[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                out.append(c)
            } else if c == UInt8(ascii: "_"), underscoreIsSpace {
                out.append(UInt8(ascii: " "))
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    static func base64(_ data: Data) -> Data {
        var s = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? Data()
    }

    static func string(_ data: Data, charset: String?) -> String {
        let name = charset?.split(separator: "*").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if !name.isEmpty, !["utf-8", "utf8", "us-ascii"].contains(name) {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Splits `type/subtype; key=value` into a lowercased value and parameters.
    static func parameters(_ header: String) -> (value: String, params: [String: String]) {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        for ch in header {
            if ch == "\"" {
                inQuote.toggle()
                current.append(ch)
            } else if ch == ";", !inQuote {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)

        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if key.hasSuffix("*") {
                key.removeLast()
                if let q = value.range(of: "''") { value = String(value[q.upperBound...]).removingPercentEncoding ?? value }
            }
            if params[key] == nil { params[key] = decodeWords(value) }
        }
        return (parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "", params)
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = [UInt8]("--\(boundary)".utf8)
        var marks: [(start: Int, end: Int, closing: Bool)] = []
        var i = 0
        while i < bytes.count {
            var lineEnd = i
            while lineEnd < bytes.count, bytes[lineEnd] != 10 { lineEnd += 1 }
            if lineEnd - i >= delimiter.count, Array(bytes[i..<(i + delimiter.count)]) == delimiter {
                let after = i + delimiter.count
                let closing = after + 1 < bytes.count && bytes[after] == UInt8(ascii: "-") && bytes[after + 1] == UInt8(ascii: "-")
                marks.append((i, min(lineEnd + 1, bytes.count), closing))
            }
            i = lineEnd + 1
        }

        var parts: [Data] = []
        for k in marks.indices where !marks[k].closing {
            let from = marks[k].end
            var to = k + 1 < marks.count ? marks[k + 1].start : bytes.count
            if to > from, bytes[to - 1] == 10 { to -= 1 }
            if to > from, bytes[to - 1] == 13 { to -= 1 }
            parts.append(to > from ? Data(bytes[from..<to]) : Data())
        }
        return parts
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}

final class MIMEPart {
    let headers: MIMEHeaders
    let body: Data
    let contentType: String
    let typeParams: [String: String]
    let children: [MIMEPart]

    init(_ data: Data, depth: Int = 0) {
        let (head, body) = MIME.split(data)
        headers = MIME.parseHeaders(head)
        self.body = body
        let type = MIME.parameters(headers["content-type"] ?? "text/plain")
        contentType = type.value.isEmpty ? "text/plain" : type.value
        typeParams = type.params
        if depth < 20, contentType.hasPrefix("multipart/"), let boundary = type.params["boundary"] {
            children = MIME.splitMultipart(body, boundary: boundary).map { MIMEPart($0, depth: depth + 1) }
        } else {
            children = []
        }
    }

    var decoded: Data {
        switch headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": return MIME.base64(body)
        case "quoted-printable": return MIME.quotedPrintable(body)
        default: return body
        }
    }

    var text: String { MIME.string(decoded, charset: typeParams["charset"]) }

    var disposition: String {
        MIME.parameters(headers["content-disposition"] ?? "").value
    }

    var filename: String? {
        MIME.parameters(headers["content-disposition"] ?? "").params["filename"] ?? typeParams["name"]
    }

    var contentID: String? {
        headers["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
    }
}
