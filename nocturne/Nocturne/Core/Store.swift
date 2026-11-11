import SwiftUI
import Combine

/// Holds the active gothic theme and the user's homelab settings (Navidrome + chat relay).
@MainActor
final class Store: ObservableObject {
    @AppStorage("themeName") private var themeName: String = GothicThemes.default.name {
        didSet { objectWillChange.send() }
    }

    // Navidrome (Subsonic API)
    @AppStorage("navURL") var navURL: String = ""
    @AppStorage("navUser") var navUser: String = ""
    @AppStorage("navPass") var navPass: String = ""   // Subsonic token auth; stored locally on-device

    // Self-hosted chat relay (jarvis-core)
    @AppStorage("relayURL") var relayURL: String = ""
    @AppStorage("relayToken") var relayToken: String = ""
    @AppStorage("displayName") var displayName: String = "Me"
    @AppStorage("chatRoom") var chatRoom: String = "home"

    var theme: GothicTheme {
        GothicThemes.all.first { $0.name == themeName } ?? GothicThemes.default
    }
    func selectTheme(_ t: GothicTheme) { themeName = t.name }
}

/// Normalises a user-typed server address into a usable base URL.
enum ServerAddress {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// Shared URLSession that tolerates self-signed homelab certs.
let netSession: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.waitsForConnectivity = true
    return URLSession(configuration: cfg, delegate: TrustDelegate(), delegateQueue: nil)
}()

final class TrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
