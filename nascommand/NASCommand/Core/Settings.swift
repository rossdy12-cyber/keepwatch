import Foundation

@MainActor
final class NASSettings: ObservableObject {
    static let shared = NASSettings()

    private static let addressKey = "nas.address"
    private static let trustKey = "nas.trustSelfSigned"
    private static let apiKeyKey = "apiKey"

    @Published var address: String {
        didSet {
            UserDefaults.standard.set(address, forKey: Self.addressKey)
            applyTrust(oldHost: ServerAddress.host(of: oldValue))
        }
    }
    @Published var trustSelfSigned: Bool {
        didSet {
            UserDefaults.standard.set(trustSelfSigned, forKey: Self.trustKey)
            applyTrust(oldHost: nil)
        }
    }
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: Self.apiKeyKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        address = defaults.string(forKey: Self.addressKey) ?? ""
        trustSelfSigned = defaults.bool(forKey: Self.trustKey)
        apiKey = Keychain.get(Self.apiKeyKey)
        applyTrust(oldHost: nil)
    }

    var isConfigured: Bool {
        !ServerAddress.normalize(address).isEmpty && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var client: TrueNASClient {
        TrueNASClient(address: address, apiKey: apiKey)
    }

    private func applyTrust(oldHost: String?) {
        if let oldHost { TrustDelegate.shared.setTrusted(host: oldHost, trusted: false) }
        TrustDelegate.shared.setTrusted(host: ServerAddress.host(of: address), trusted: trustSelfSigned)
    }
}
