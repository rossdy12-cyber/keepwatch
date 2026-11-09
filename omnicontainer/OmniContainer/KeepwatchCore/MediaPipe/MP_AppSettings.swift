import Foundation
import SwiftUI

@MainActor
final class MPAppSettings: ObservableObject {
    private enum StoredKey {
        static let serverBaseURL = "metube.server.baseURL"
        static let apiToken = "metube.apiToken"
        static let defaultFolder = "metube.defaultFolder"
    }

    private enum SharedKey {
        static let serverBaseURL = "shareExtension.serverBaseURL"
        static let apiToken = "shareExtension.apiToken"
        static let defaultFolder = "shareExtension.defaultFolder"
        static let outputType = "shareExtension.outputType"
        static let quality = "shareExtension.quality"
    }

    static let appGroupID = "group.uk.co.rossdymond.mediapipe"

    @Published var serverBaseURL: String {
        didSet { UserDefaults.standard.set(serverBaseURL, forKey: StoredKey.serverBaseURL) }
    }

    @Published var apiToken: String {
        didSet {
            if apiToken.isEmpty {
                MPKeychainStore.delete(account: StoredKey.apiToken)
            } else {
                MPKeychainStore.save(apiToken, account: StoredKey.apiToken)
            }
        }
    }

    @Published var defaultFolder: String {
        didSet {
            UserDefaults.standard.set(defaultFolder, forKey: StoredKey.defaultFolder)
            sharedDefaults?.set(defaultFolder, forKey: SharedKey.defaultFolder)
        }
    }

    @Published var sharedBaseURL: String {
        didSet { sharedDefaults?.set(sharedBaseURL, forKey: SharedKey.serverBaseURL) }
    }

    @Published var sharedToken: String {
        didSet { sharedDefaults?.set(sharedToken, forKey: SharedKey.apiToken) }
    }

    @Published var sharedOutputType: MPOutputType {
        didSet { sharedDefaults?.set(sharedOutputType.rawValue, forKey: SharedKey.outputType) }
    }

    @Published var sharedQuality: String {
        didSet { sharedDefaults?.set(sharedQuality, forKey: SharedKey.quality) }
    }

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupID)
    }

    var serverProfile: MPServerProfile {
        MPServerProfile(
            name: "MeTube",
            baseURL: serverBaseURL,
            usesToken: !apiToken.isEmpty
        )
    }

    var isConfigured: Bool {
        !serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        let savedBaseURL = UserDefaults.standard.string(forKey: StoredKey.serverBaseURL) ?? ""
        let initialBaseURL = savedBaseURL.isEmpty ? "https://metube.nas-server.co.uk" : savedBaseURL
        let initialToken = MPKeychainStore.load(account: StoredKey.apiToken) ?? ""
        serverBaseURL = initialBaseURL
        apiToken = initialToken
        defaultFolder = UserDefaults.standard.string(forKey: StoredKey.defaultFolder) ?? "Music-Videos"

        let shared = UserDefaults(suiteName: Self.appGroupID)
        sharedBaseURL = shared?.string(forKey: SharedKey.serverBaseURL) ?? initialBaseURL
        sharedToken = shared?.string(forKey: SharedKey.apiToken) ?? initialToken
        sharedOutputType = MPOutputType(rawValue: shared?.string(forKey: SharedKey.outputType) ?? "") ?? .video
        sharedQuality = shared?.string(forKey: SharedKey.quality) ?? "best"

        syncSharedSettings()
    }

    func syncSharedSettings() {
        sharedDefaults?.set(sharedBaseURL, forKey: SharedKey.serverBaseURL)
        sharedDefaults?.set(sharedToken, forKey: SharedKey.apiToken)
        sharedDefaults?.set(defaultFolder, forKey: SharedKey.defaultFolder)
        sharedDefaults?.set(sharedOutputType.rawValue, forKey: SharedKey.outputType)
        sharedDefaults?.set(sharedQuality, forKey: SharedKey.quality)
    }
}
