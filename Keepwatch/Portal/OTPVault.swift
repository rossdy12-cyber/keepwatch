import Foundation

/// The 2FA accounts, kept in the iPhone Keychain (this device only, never backed up or synced).
@MainActor
final class OTPVault: ObservableObject {
    static let shared = OTPVault()
    private static let key = "otp.accounts"

    @Published var accounts: [OTPAccount] {
        didSet { Keychain.save(accounts, for: Self.key) }
    }

    @Published var autoFill: Bool {
        didSet { UserDefaults.standard.set(autoFill, forKey: "otp.autoFill") }
    }

    private init() {
        accounts = Keychain.load([OTPAccount].self, for: Self.key) ?? []
        autoFill = UserDefaults.standard.object(forKey: "otp.autoFill") as? Bool ?? true
    }

    /// The most specific account for a host, e.g. Authelia's for auth.nas-server.co.uk, TrueNAS's for nas-server.co.uk.
    func account(for host: String?) -> OTPAccount? {
        guard let host, !host.isEmpty else { return nil }
        return accounts
            .compactMap { account in account.matchStrength(host: host).map { (account, $0) } }
            .max { $0.1 < $1.1 }?.0
    }
}
