import Foundation
import SwiftUI

@MainActor
final class VSAppSettings: ObservableObject {
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
                VSKeychainStore.delete(account: StoredKey.password)
            } else {
                VSKeychainStore.save(password, account: StoredKey.password)
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
        let savedURL = UserDefaults.standard.string(forKey: StoredKey.serverBaseURL) ?? ""
        let savedUser = UserDefaults.standard.string(forKey: StoredKey.username) ?? ""
        let savedPass = VSKeychainStore.load(account: StoredKey.password) ?? ""
        serverBaseURL = savedURL.isEmpty ? "https://vault.nas-server.co.uk/private-files" : savedURL
        username = savedUser.isEmpty ? "NISES" : savedUser
        password = savedPass.isEmpty ? "92YYgGXfmDLh4x" : savedPass
        remoteFolder = UserDefaults.standard.string(forKey: StoredKey.remoteFolder) ?? "Documents"
    }
}
