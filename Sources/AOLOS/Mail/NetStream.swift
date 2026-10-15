import Foundation
import Network

enum MailError: LocalizedError {
    case closed
    case timeout
    case notConnected
    case protocolError(String)
    case commandFailed(String)
    case auth(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "The mail server closed the connection."
        case .timeout: return "The mail server did not respond in time."
        case .notConnected: return "Gmail is not connected."
        case .protocolError(let s): return "Unexpected reply from the mail server: \(s)"
        case .commandFailed(let s): return "The mail server refused the request: \(s)"
        case .auth(let s): return s
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// A TLS byte stream with line and fixed-length reads, shared by IMAP and SMTP.
actor NetStream {
    private let connection: NWConnection
    private var buffer = Data()

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
    }

    func open() async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.take() {
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: MailError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func close() {
        connection.cancel()
    }

    func readLine() async throws -> Data {
        while true {
            if let r = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            buffer.append(try await receive())
        }
    }

    func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await receive())
        }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    func write(_ data: Data) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive() async throws -> Data {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: MailError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
