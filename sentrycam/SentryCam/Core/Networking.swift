import Foundation

/// A URLSession that can trust a self-signed certificate on the Frigate host (it ships one on :8971), and that
/// keeps Frigate's login cookie so snapshots, events and clips are authorised.
let httpSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 25
    config.httpCookieStorage = .shared
    config.httpCookieAcceptPolicy = .always
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
        completionHandler(allow ? .useCredential : .performDefaultHandling, allow ? URLCredential(trust: trust) : nil)
    }
}

enum FrigateError: LocalizedError {
    case notConfigured, invalidURL, http(Int), loginFailed
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Frigate address in Settings."
        case .invalidURL: return "That Frigate address doesn't look right."
        case .http(let code): return "Frigate returned HTTP \(code)."
        case .loginFailed: return "Frigate didn't accept that username or password."
        }
    }
}

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
    static func host(of raw: String) -> String? { URL(string: normalize(raw))?.host }
}

func describeError(_ error: Error) -> String {
    if let e = error as? FrigateError { return e.errorDescription ?? "Something went wrong." }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost: return "Couldn't reach Frigate at that address."
        case .timedOut: return "Frigate didn't respond in time."
        case .serverCertificateUntrusted, .secureConnectionFailed:
            return "Frigate's certificate wasn't trusted. Turn on \u{201C}Accept self-signed certificate\u{201D} in Settings."
        default: return urlError.localizedDescription
        }
    }
    return error.localizedDescription
}
