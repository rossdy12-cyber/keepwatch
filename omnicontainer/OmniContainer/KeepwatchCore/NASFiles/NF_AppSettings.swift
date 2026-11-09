import Foundation
import SwiftUI

@MainActor
final class NFAppSettings: ObservableObject {
    private enum StoredKey {
        static let serverBaseURL = "nasfiles.server.baseURL"
        static let username = "nasfiles.server.username"
        static let password = "nasfiles.server.password"
        static let rootPath = "nasfiles.server.rootPath"
        static let favourites = "nasfiles.favourites"
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
                NFKeychainStore.delete(account: StoredKey.password)
            } else {
                NFKeychainStore.save(password, account: StoredKey.password)
            }
        }
    }

    @Published var rootPath: String {
        didSet { UserDefaults.standard.set(rootPath, forKey: StoredKey.rootPath) }
    }

    @Published var favouritePaths: [String] {
        didSet { UserDefaults.standard.set(favouritePaths, forKey: StoredKey.favourites) }
    }

    var serverProfile: NFServerProfile {
        NFServerProfile(
            baseURL: serverBaseURL,
            username: username,
            usesPassword: !password.isEmpty
        )
    }

    var isConfigured: Bool {
        !serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    var rootDirectory: String {
        let cleaned = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty ? "/" : "/\(cleaned)"
    }

    init() {
        let savedURL = UserDefaults.standard.string(forKey: StoredKey.serverBaseURL) ?? ""
        let savedUser = UserDefaults.standard.string(forKey: StoredKey.username) ?? ""
        let savedPass = NFKeychainStore.load(account: StoredKey.password) ?? ""
        if savedURL.isEmpty || savedURL.contains("vault.nas-server.co.uk") {
            serverBaseURL = "https://files.nas-server.co.uk"
            UserDefaults.standard.set("https://files.nas-server.co.uk", forKey: StoredKey.serverBaseURL)
        } else {
            serverBaseURL = savedURL
        }
        username = savedUser.isEmpty ? "NISES" : savedUser
        password = savedPass.isEmpty ? "92YYgGXfmDLh4x" : savedPass
        rootPath = UserDefaults.standard.string(forKey: StoredKey.rootPath) ?? ""
        favouritePaths = UserDefaults.standard.stringArray(forKey: StoredKey.favourites) ?? []
    }

    func toggleFavourite(_ path: String) {
        if favouritePaths.contains(path) {
            favouritePaths.removeAll { $0 == path }
        } else {
            favouritePaths.append(path)
        }
    }
}
