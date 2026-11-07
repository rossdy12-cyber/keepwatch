import Foundation

/// URLSession for the optional WebDAV backup; can trust a self-signed cert on the NAS host.
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
        completionHandler(allow ? .useCredential : .performDefaultHandling, allow ? URLCredential(trust: trust) : nil)
    }
}

enum ServerAddress {
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    static func host(of raw: String) -> String? { URL(string: normalize(raw))?.host }
}

func describeError(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .userAuthenticationRequired: return "The NAS rejected the backup username or password."
        case .cannotFindHost, .cannotConnectToHost: return "Couldn't reach the NAS at that address."
        case .timedOut: return "The NAS didn't respond in time."
        case .serverCertificateUntrusted, .secureConnectionFailed:
            return "The NAS certificate wasn't trusted. Turn on \u{201C}Accept self-signed certificate\u{201D}."
        default: return urlError.localizedDescription
        }
    }
    return error.localizedDescription
}
