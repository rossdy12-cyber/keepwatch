import Foundation

/// The user's authenticator accounts, persisted (encrypted at rest) in the Keychain.
@MainActor
final class Vault: ObservableObject {
    @Published private(set) var accounts: [OTPAccount] = []
    private static let storeKey = "vault.accounts.v1"

    init() { load() }

    private func load() {
        guard let data = Keychain.getData(Self.storeKey),
              let list = try? JSONDecoder().decode([OTPAccount].self, from: data) else { return }
        accounts = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) { Keychain.setData(data, for: Self.storeKey) }
    }

    /// True if an account with the same secret already exists.
    func contains(secret: String) -> Bool {
        let norm = secret.replacingOccurrences(of: " ", with: "").uppercased()
        return accounts.contains { $0.config.secret.replacingOccurrences(of: " ", with: "").uppercased() == norm }
    }

    @discardableResult
    func add(_ account: OTPAccount) -> Bool {
        guard !contains(secret: account.config.secret) else { return false }
        accounts.append(account)
        persist()
        return true
    }

    func delete(_ account: OTPAccount) {
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    func delete(at offsets: IndexSet) { accounts.remove(atOffsets: offsets); persist() }
    func move(from: IndexSet, to: Int) { accounts.move(fromOffsets: from, toOffset: to); persist() }

    /// Replace everything (used by Restore). Skips exact-duplicate secrets if `merge` is true.
    func replaceAll(_ list: [OTPAccount], merge: Bool) {
        if merge {
            var combined = accounts
            for account in list where !combined.contains(where: { $0.config.secret.uppercased() == account.config.secret.uppercased() }) {
                combined.append(account)
            }
            accounts = combined
        } else {
            accounts = list
        }
        persist()
    }
}
