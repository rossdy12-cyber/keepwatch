import Foundation

enum MailError: LocalizedError {
    case connectionClosed
    case timeout
    case server(String)
    case auth(String)
    case protocolError(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .connectionClosed: return "The server closed the connection."
        case .timeout: return "The server took too long to answer."
        case .server(let text): return text
        case .auth(let text): return "Sign-in failed: \(text)"
        case .protocolError(let text): return "Unexpected reply from the server: \(text)"
        case .notConfigured: return "No mail account is set up yet."
        }
    }
}

/// A plain TCP connection that can switch to TLS, either straight away (IMAP on 993,
/// SMTP on 465) or after a STARTTLS command (SMTP on 587). Built on URLSessionStreamTask,
/// which validates the server certificate against the host name.
final class StreamConnection {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer = Data()
    var timeout: TimeInterval = 40

    init(host: String, port: Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
        task = session.streamTask(withHostName: host, port: port)
        task.resume()
    }

    deinit {
        close()
    }

    func startTLS() {
        task.startSecureConnection()
    }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }

    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    func write(_ data: Data) async throws {
        let timeout = self.timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: timeout) { error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func fill() async throws {
        let timeout = self.timeout
        let (data, atEOF): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
            task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout) { data, atEOF, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                } else {
                    continuation.resume(returning: (data, atEOF))
                }
            }
        }
        if let data, !data.isEmpty {
            buffer.append(data)
        } else if atEOF {
            throw MailError.connectionClosed
        }
    }

    /// Reads one line, without its CRLF, as raw bytes.
    func readLineData() async throws -> Data {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            try await fill()
        }
    }

    func readLine() async throws -> String {
        let data = try await readLineData()
        return String(decoding: data, as: UTF8.self)
    }

    func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill()
        }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    private static func mapError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return MailError.timeout
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return MailError.server("Couldn't find the mail server. Check the server name.")
            case NSURLErrorCannotConnectToHost:
                return MailError.server("Couldn't connect to the mail server. Check the server name and port.")
            case NSURLErrorNotConnectedToInternet:
                return MailError.server("You're offline.")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                return MailError.server("A secure connection to the mail server couldn't be made.")
            default: break
            }
        }
        return error
    }
}
