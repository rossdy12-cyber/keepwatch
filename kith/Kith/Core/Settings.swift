import Foundation

@MainActor
final class KithSettings: ObservableObject {
    static let shared = KithSettings()

    @Published var coreURL: String { didSet { UserDefaults.standard.set(coreURL, forKey: "kith.core"); applyTrust(old: ServerAddress.host(of: oldValue)) } }
    @Published var token: String { didSet { Keychain.set(token, for: "core.token") } }
    @Published var trustSelfSigned: Bool { didSet { UserDefaults.standard.set(trustSelfSigned, forKey: "kith.trust"); applyTrust(old: nil) } }

    init() {
        let d = UserDefaults.standard
        coreURL = d.string(forKey: "kith.core") ?? "https://jarvis.nas-server.co.uk"
        trustSelfSigned = d.object(forKey: "kith.trust") as? Bool ?? false
        token = Keychain.get("core.token")
        applyTrust(old: nil)
    }

    var isConfigured: Bool { !ServerAddress.normalize(coreURL).isEmpty }
    var client: KithClient { KithClient(coreURL: coreURL, token: token) }

    private func applyTrust(old: String?) {
        if let old { TrustDelegate.shared.setTrusted(host: old, trusted: false) }
        TrustDelegate.shared.setTrusted(host: ServerAddress.host(of: coreURL), trusted: trustSelfSigned)
    }
}
