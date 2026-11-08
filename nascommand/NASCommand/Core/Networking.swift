import Foundation

/// A URLSession that can optionally trust a self-signed certificate on the configured NAS host.
let httpSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 25
    config.waitsForConnectivity = false
    return URLSession(configuration: config, delegate: TrustDelegate.shared, delegateQueue: nil)
}()

final class TrustDelegate: NSObject, URLSessionDelegate {
    static let shared = TrustDelegate()
    private let lock = NSLock()
    private var trustedHosts: Set<String> = []

    func setTrusted(host: String?, trusted: Bool) {
        guard let host, !host.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if trusted { trustedHosts.insert(host.lowercased()) } else { trustedHosts.remove(host.lowercased()) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        lock.lock()
        let allow = trustedHosts.contains(challenge.protectionSpace.host.lowercased())
        lock.unlock()
        if allow {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum NASError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(Int, String?)
    case unauthorized
    case notJSON

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your TrueNAS address and API key in Settings."
        case .invalidURL: return "That TrueNAS address doesn't look right."
        case .unauthorized: return "TrueNAS rejected the API key. Check it in Settings."
        case .http(let code, let detail): return detail?.isEmpty == false ? detail! : "TrueNAS returned HTTP \(code)."
        case .notJSON: return "TrueNAS sent something unexpected (is the address right?)."
        }
    }
}

/// Tidies a typed address into a base URL (adds https:// if no scheme, trims a trailing slash).
enum ServerAddress {
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func host(of raw: String) -> String? {
        URL(string: normalize(raw))?.host
    }
}

func describeError(_ error: Error) -> String {
    if let nas = error as? NASError { return nas.errorDescription ?? "Something went wrong." }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost: return "No network connection."
        case .cannotFindHost, .cannotConnectToHost: return "Couldn't reach the NAS at that address."
        case .timedOut: return "The NAS didn't respond in time."
        case .serverCertificateUntrusted, .secureConnectionFailed:
            return "The NAS's certificate wasn't trusted. Turn on \u{201C}Accept self-signed certificate\u{201D} in Settings."
        default: return urlError.localizedDescription
        }
    }
    return error.localizedDescription
}
