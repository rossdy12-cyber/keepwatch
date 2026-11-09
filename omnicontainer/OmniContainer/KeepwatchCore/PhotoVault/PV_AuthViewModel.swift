import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class PVAuthViewModel: ObservableObject {
    @Published var serverURL: String = ""
    @Published var username: String = ""
    @Published var appPassword: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isAuthenticated = false
    @Published var isUnlocked = false

    private(set) var client: PVPhotoPrismClient?

    private enum Key {
        static let server = "serverURL"
        static let username = "username"
        static let token = "sessionToken"
    }

    init() {
        serverURL = PVKeychainStore.read(Key.server) ?? ""
        username = PVKeychainStore.read(Key.username) ?? ""

        if let savedServer = PVKeychainStore.read(Key.server),
           let savedToken = PVKeychainStore.read(Key.token),
           let url = try? PVPhotoPrismClient.normaliseServerURL(savedServer) {
            client = PVPhotoPrismClient(baseURL: url, token: savedToken)
            isAuthenticated = true
        }
    }

    func signIn() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let url = try PVPhotoPrismClient.normaliseServerURL(serverURL)
            let newClient = PVPhotoPrismClient(baseURL: url)
            let token = try await newClient.createSession(username: username, appPassword: appPassword)

            PVKeychainStore.save(serverURL, forKey: Key.server)
            PVKeychainStore.save(username, forKey: Key.username)
            PVKeychainStore.save(token, forKey: Key.token)

            client = newClient
            isAuthenticated = true
            appPassword = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestUnlock() async {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            isUnlocked = true
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock your private PhotoPrism library."
            )
            isUnlocked = success
        } catch {
            isUnlocked = false
        }
    }

    func signOut() {
        PVKeychainStore.delete(Key.server)
        PVKeychainStore.delete(Key.username)
        PVKeychainStore.delete(Key.token)

        serverURL = ""
        username = ""
        appPassword = ""
        client = nil
        isAuthenticated = false
        isUnlocked = false
    }
}
