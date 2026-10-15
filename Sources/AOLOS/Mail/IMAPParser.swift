import Foundation

/// One server response. Literal bytes are pulled out of `text`, which keeps the `{n}` markers in place.
struct IMAPResponse {
    let text: String
    let literals: [Data]

    var isUntagged: Bool { text.hasPrefix("* ") }
    var isContinuation: Bool { text.hasPrefix("+") }

    /// Returns the byte count when a line ends with a literal marker such as `{123}`.
    static func trailingLiteralLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        return Int(digits)
    }
}

indirect enum IMAPValue: Equatable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    var data: Data? {
        switch self {
        case .atom(let s): return Data(s.utf8)
        case .string(let d): return d
        default: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }
}

struct IMAPParser {
    private let bytes: [UInt8]
    private let literals: [Data]
    private var index = 0
    private var literalIndex = 0

    init(_ response: IMAPResponse) {
        bytes = Array(response.text.utf8)
        literals = response.literals
    }

    mutating func next() -> IMAPValue? {
        skipSpaces()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "("):
            index += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard index < bytes.count else { break }
                if bytes[index] == UInt8(ascii: ")") {
                    index += 1
                    break
                }
                guard let value = next() else { break }
                items.append(value)
            }
            return .list(items)

        case UInt8(ascii: "\""):
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let b = bytes[index]
                index += 1
                if b == UInt8(ascii: "\\"), index < bytes.count {
                    out.append(bytes[index])
                    index += 1
                } else if b == UInt8(ascii: "\"") {
                    break
                } else {
                    out.append(b)
                }
            }
            return .string(Data(out))

        case UInt8(ascii: "{"):
            while index < bytes.count, bytes[index] != UInt8(ascii: "}") { index += 1 }
            index += 1
            let data = literalIndex < literals.count ? literals[literalIndex] : Data()
            literalIndex += 1
            return .string(data)

        default:
            let start = index
            var depth = 0
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "[") {
                    depth += 1
                } else if b == UInt8(ascii: "]") {
                    depth -= 1
                } else if depth == 0, b == UInt8(ascii: " ") || b == UInt8(ascii: "(") || b == UInt8(ascii: ")") {
                    break
                }
                index += 1
            }
            if index == start {
                index += 1
                return nil
            }
            let atom = String(decoding: bytes[start..<index], as: UTF8.self)
            return atom.uppercased() == "NIL" ? .nilValue : .atom(atom)
        }
    }

    private mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
    }

    /// Parses `* n FETCH (KEY value ...)` into uppercase keys.
    static func fetchItems(_ response: IMAPResponse) -> [String: IMAPValue]? {
        var p = IMAPParser(response)
        guard p.next()?.text == "*", p.next() != nil,
              p.next()?.text?.uppercased() == "FETCH",
              let list = p.next()?.list else { return nil }
        var items: [String: IMAPValue] = [:]
        var k = 0
        while k + 1 < list.count {
            if let key = list[k].text?.uppercased() { items[key] = list[k + 1] }
            k += 2
        }
        return items
    }

    /// Parses `* LIST (attributes) "delimiter" name`.
    static func listEntry(_ response: IMAPResponse) -> (name: String, attributes: [String])? {
        var p = IMAPParser(response)
        guard p.next()?.text == "*", p.next()?.text?.uppercased() == "LIST",
              let attributes = p.next()?.list else { return nil }
        _ = p.next()
        guard let name = p.next()?.text else { return nil }
        return (name, attributes.compactMap { $0.text })
    }

    /// Parses `* SEARCH 1 2 3`.
    static func searchUIDs(_ response: IMAPResponse) -> [UInt32]? {
        let parts = response.text.split(separator: " ")
        guard parts.count >= 2, parts[0] == "*", parts[1].uppercased() == "SEARCH" else { return nil }
        return parts.dropFirst(2).compactMap { UInt32($0) }
    }

    /// Compresses UIDs into an IMAP sequence set such as `1:3,7,9:10`.
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            ranges.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return ranges.joined(separator: ",")
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
