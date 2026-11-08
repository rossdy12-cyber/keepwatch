import Foundation

@MainActor
final class FrigateSettings: ObservableObject {
    static let shared = FrigateSettings()

    @Published var address: String { didSet { save(); applyTrust(oldHost: ServerAddress.host(of: oldValue)) } }
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: "frigate.user") } }
    @Published var password: String { didSet { Keychain.set(password, for: "frigate.pass") } }
    @Published var trustSelfSigned: Bool { didSet { UserDefaults.standard.set(trustSelfSigned, forKey: "frigate.trust"); applyTrust(oldHost: nil) } }
    /// Optional NAS agent for Tapo PTZ/patrol control (your antigravity exec endpoint). Empty = hide that card.
    @Published var agentURL: String { didSet { UserDefaults.standard.set(agentURL, forKey: "frigate.agent") } }

    private func save() { UserDefaults.standard.set(address, forKey: "frigate.address") }

    init() {
        let d = UserDefaults.standard
        address = d.string(forKey: "frigate.address") ?? ""
        username = d.string(forKey: "frigate.user") ?? ""
        trustSelfSigned = d.object(forKey: "frigate.trust") as? Bool ?? true
        agentURL = d.string(forKey: "frigate.agent") ?? ""
        password = Keychain.get("frigate.pass")
        applyTrust(oldHost: nil)
    }

    var isConfigured: Bool { !ServerAddress.normalize(address).isEmpty }
    var needsLogin: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty }

    var client: FrigateClient {
        FrigateClient(address: address, username: username, password: password)
    }

    private func applyTrust(oldHost: String?) {
        if let oldHost { TrustDelegate.shared.setTrusted(host: oldHost, trusted: false) }
        TrustDelegate.shared.setTrusted(host: ServerAddress.host(of: address), trusted: trustSelfSigned)
    }
}
