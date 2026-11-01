import Foundation

enum JarvisError: LocalizedError {
    case notConfigured
    case invalidURL
    case unauthorized
    case cloudflareAccess
    case cloudflare(Int)
    case notFound(String)
    case http(Int, String?)
    case webPage
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add the Jarvis address in Settings first."
        case .invalidURL:
            return "That address doesn't look right. It should look like https://jarvis.nas-server.co.uk"
        case .unauthorized:
            return "Jarvis refused the access token. Check it in Settings."
        case .cloudflareAccess:
            return "Cloudflare Access is asking for a login. Add a Cloudflare Access service token in Settings, or add a bypass rule for this app."
        case .cloudflare(let code):
            return Self.cloudflareMessage(code)
        case .notFound(let path):
            return "Jarvis has no \(path) endpoint (HTTP 404). Check the connection type and chat path in Settings, or tap Test connection to detect them."
        case .http(let code, let detail):
            if let detail, !detail.isEmpty { return "Jarvis answered with an error (HTTP \(code)): \(detail)" }
            return "Jarvis answered with an error (HTTP \(code))."
        case .webPage:
            return "Got a web page instead of an answer. The chat path is probably wrong, or a login page is in the way."
        case .emptyReply:
            return "Jarvis sent an empty reply."
        }
    }

    private static func cloudflareMessage(_ code: Int) -> String {
        let prefix = "Cloudflare couldn't get through to Jarvis on your NAS (error \(code)). "
        switch code {
        case 521:
            return prefix + "The NAS refused the connection: is the Jarvis app running, and is Cloudflare pointing at the right port?"
        case 522, 524:
            return prefix + "The NAS didn't answer in time."
        case 523:
            return prefix + "Cloudflare can't reach the NAS at all. Check the DNS record or tunnel."
        case 525:
            return prefix + "The secure (SSL) handshake failed: Cloudflare is set to talk https to the NAS, but Jarvis on that port only speaks http. In Cloudflare, either set SSL/TLS to Flexible for this host, or (better) point a Cloudflare Tunnel at http://<nas-ip>:<jarvis-port>."
        case 526:
            return prefix + "The NAS's certificate isn't valid for this name. Use Cloudflare SSL mode Full (not Full strict), or install a Cloudflare Origin certificate on the NAS."
        case 530:
            return prefix + "The Cloudflare Tunnel is offline or not linked to this hostname. Check the cloudflared app on TrueNAS."
        default:
            return prefix + "Check that Jarvis is running on TrueNAS."
        }
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// A friendlier message for errors that people see on screen.
func describe(_ error: Error) -> String {
    if let urlError = error as? URLError {
        let code = " (error \(urlError.code.rawValue))"
        switch urlError.code {
        case .notConnectedToInternet:
            return "The iPhone is offline." + code
        case .cannotFindHost, .dnsLookupFailed:
            return "That address couldn't be found. Check the spelling in Settings." + code
        case .cannotConnectToHost, .networkConnectionLost:
            return "Couldn't reach Jarvis. Check the address and that the Jarvis app is running (and Tailscale is on, for a 100.x address)." + code
        case .timedOut:
            return "Jarvis took too long to answer." + code
        case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "The server's certificate wasn't accepted. For a self-signed certificate, turn on \"Accept self-signed certificate\" in Settings." + code
        default:
            return urlError.localizedDescription + code
        }
    }
    return error.localizedDescription
}

enum ServerAddress {
    /// Trims whitespace, adds `https://` when no scheme was typed and drops trailing slashes.
    static func normalize(_ raw: String, defaultScheme: String = "https") -> String {
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

/// Accepts self-signed certificates, but only for the host the user has explicitly allowed in Settings.
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
    config.timeoutIntervalForRequest = 120
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config, delegate: TrustDelegate.shared, delegateQueue: nil)
}()
