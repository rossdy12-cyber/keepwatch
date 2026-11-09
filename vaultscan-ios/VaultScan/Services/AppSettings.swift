import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum StoredKey {
        static let serverBaseURL = "vaultscan.server.baseURL"
        static let username = "vaultscan.server.username"
        static let password = "vaultscan.server.password"
        static let remoteFolder = "vaultscan.server.remoteFolder"
    }

    @Published var serverBaseURL: String {
        didSet { UserDefaults.standard.set(serverBaseURL, forKey: StoredKey.serverBaseURL) }
    }

    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: StoredKey.username) }
    }

    @Published var password: String {
        didSet {
            if password.isEmpty {
                KeychainStore.delete(account: StoredKey.password)
            } else {
                KeychainStore.save(password, account: StoredKey.password)
            }
        }
    }

    @Published var remoteFolder: String {
        didSet { UserDefaults.standard.set(remoteFolder, forKey: StoredKey.remoteFolder) }
    }

    var isConfigured: Bool {
        !serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    var normalizedBaseURL: URL? {
        var value = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty {
            return nil
        }

        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://\(value)"
        }

        return URL(string: value)
    }

    init() {
        serverBaseURL = UserDefaults.standard.string(forKey: StoredKey.serverBaseURL) ?? ""
        username = UserDefaults.standard.string(forKey: StoredKey.username) ?? ""
        password = KeychainStore.load(account: StoredKey.password) ?? ""
        remoteFolder = UserDefaults.standard.string(forKey: StoredKey.remoteFolder) ?? "Documents"
    }
}
