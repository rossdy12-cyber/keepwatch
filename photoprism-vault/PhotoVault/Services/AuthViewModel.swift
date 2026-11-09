import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var serverURL: String = ""
    @Published var username: String = ""
    @Published var appPassword: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isAuthenticated = false
    @Published var isUnlocked = false

    private(set) var client: PhotoPrismClient?

    private enum Key {
        static let server = "serverURL"
        static let username = "username"
        static let token = "sessionToken"
    }

    init() {
        serverURL = KeychainStore.read(Key.server) ?? ""
        username = KeychainStore.read(Key.username) ?? ""

        if let savedServer = KeychainStore.read(Key.server),
           let savedToken = KeychainStore.read(Key.token),
           let url = try? PhotoPrismClient.normaliseServerURL(savedServer) {
            client = PhotoPrismClient(baseURL: url, token: savedToken)
            isAuthenticated = true
        }
    }

    func signIn() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let url = try PhotoPrismClient.normaliseServerURL(serverURL)
            let newClient = PhotoPrismClient(baseURL: url)
            let token = try await newClient.createSession(username: username, appPassword: appPassword)

            KeychainStore.save(serverURL, forKey: Key.server)
            KeychainStore.save(username, forKey: Key.username)
            KeychainStore.save(token, forKey: Key.token)

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
        KeychainStore.delete(Key.server)
        KeychainStore.delete(Key.username)
        KeychainStore.delete(Key.token)

        serverURL = ""
        username = ""
        appPassword = ""
        client = nil
        isAuthenticated = false
        isUnlocked = false
    }
}
