import Foundation

enum APIError: LocalizedError {
    case notConfigured(String)
    case invalidURL
    case insecureTrueNAS
    case proxiedTrueNAS
    case cloudflareTrueNAS
    case http(Int)
    case server(String)
    case unauthorized(String)
    case timeout
    case notTheRightServer(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let service):
            return "\(service) isn't set up yet. Add its address and key in Settings."
        case .invalidURL:
            return "That address doesn't look right. It should look like http://100.x.x.x:30027"
        case .insecureTrueNAS:
            return "Use https:// for TrueNAS. TrueNAS switches off an API key as soon as it is sent over plain http."
        case .proxiedTrueNAS:
            return "Use your NAS's Tailscale IP (https://100.x.x.x) for TrueNAS. A domain name usually goes through Cloudflare or a proxy, which passes the key on over plain http, and TrueNAS then switches the key off. The key wasn't sent."
        case .cloudflareTrueNAS:
            return "That address goes through Cloudflare, which passes the key on to TrueNAS over plain http, and TrueNAS would switch the key off. The key wasn't sent. Use your NAS's Tailscale IP (https://100.x.x.x) instead."
        case .http(let code):
            return "The server answered with an error (HTTP \(code))."
        case .server(let message):
            return message
        case .unauthorized(let service):
            return "\(service) refused the key or password. Check it in Settings."
        case .timeout:
            return "The server took too long to answer. Is Tailscale on?"
        case .notTheRightServer(let service):
            return "Something answered at that address, but it doesn't look like \(service). Check the port number."
        }
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// A friendlier message for network errors that people see on screen.
func describe(_ error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost:
            return "Couldn't reach the server. Check that Tailscale is on and the address is right."
        case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "The server's certificate isn't trusted. Turn on \"Accept self-signed certificate\" in Settings."
        default:
            break
        }
    }
    return error.localizedDescription
}

enum ServerAddress {
    /// Trims whitespace, adds `http://` when no scheme was typed and drops trailing slashes.
    static func normalize(_ raw: String, defaultScheme: String = "http") -> String {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "" }
        let lower = address.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            address = "\(defaultScheme)://" + address
        }
        while address.hasSuffix("/") {
            address.removeLast()
        }
        return address
    }
}

func makeURL(base: String, path: String, query: [URLQueryItem] = []) -> URL? {
    guard var components = URLComponents(string: base + path) else { return nil }
    if !query.isEmpty {
        components.queryItems = (components.queryItems ?? []) + query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    return components.url
}

/// Accepts self-signed certificates, but only for hosts the user has explicitly allowed in Settings
/// (TrueNAS ships with a self-signed certificate).
final class TrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = TrustDelegate()

    private let lock = NSLock()
    private var trustedHosts: Set<String> = []

    func setTrusted(host: String?, trusted: Bool) {
        guard let host = host?.lowercased() else { return }
        lock.lock()
        if trusted { trustedHosts.insert(host) } else { trustedHosts.remove(host) }
        lock.unlock()
    }

    private func isTrusted(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trustedHosts.contains(host.lowercased())
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           isTrusted(challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

let httpSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 20
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config, delegate: TrustDelegate.shared, delegateQueue: nil)
}()

/// Sends a request and returns the parsed JSON body, mapping 401/403 to `.unauthorized`.
func fetchJSON(_ request: URLRequest, service: String) async throws -> JSONValue {
    let (data, response) = try await httpSession.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.server("No response from \(service).") }
    if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized(service) }
    guard (200..<300).contains(http.statusCode) else {
        if let message = (try? JSONValue.parse(data))?["message"].string, !message.isEmpty {
            throw APIError.server("\(service): \(message)")
        }
        throw APIError.http(http.statusCode)
    }
    if data.isEmpty { return .null }
    do {
        return try JSONValue.parse(data)
    } catch {
        throw APIError.notTheRightServer(service)
    }
}
