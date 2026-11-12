import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Registers this iPhone with the Crypt relay on your NAS. The relay keeps a live IMAP
/// connection to each account and sends an Apple push when new mail arrives.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "crypt.push.enabled") }
    }
    @Published var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: "crypt.push.relay") }
    }
    @Published private(set) var deviceToken: String?
    @Published private(set) var status: String = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var busy = false
    @Published private(set) var lastSynced: Date?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "crypt.push.enabled")
        relayURL = UserDefaults.standard.string(forKey: "crypt.push.relay") ?? ""
    }

    var secret: String {
        get { Keychain.read(account: "relay-secret") ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete(account: "relay-secret") } else { Keychain.save(newValue, account: "relay-secret") }
            objectWillChange.send()
        }
    }

    var isConfigured: Bool { !relayURL.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty }

    // MARK: Lifecycle

    /// Called at launch: re-registers with Apple so the token is fresh.
    func resume() {
        guard enabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func turnOn() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                enabled = false
                setStatus("Notifications are turned off for Crypt in iPhone Settings.", error: true)
                return
            }
        } catch {
            enabled = false
            setStatus(error.localizedDescription, error: true)
            return
        }
        enabled = true
        setStatus("Asking Apple for a push token…", error: false)
        UIApplication.shared.registerForRemoteNotifications()
    }

    func turnOff() async {
        enabled = false
        if deviceToken != nil, isConfigured {
            _ = try? await post("/unregister", body: ["device_token": deviceToken ?? ""])
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        lastSynced = nil
        setStatus("Notifications are off.", error: false)
    }

    func didRegister(token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await sync() }
    }

    func didFailToRegister(_ error: Error) {
        let text = error.localizedDescription
        if text.contains("aps-environment") {
            setStatus("This copy of Crypt isn't allowed to receive push. Install it with Sideloadly using your paid developer Apple ID.", error: true)
        } else {
            setStatus("Apple refused a push token: \(text)", error: true)
        }
    }

    // MARK: Relay

    /// Sends the device token and every account to the relay.
    func sync() async {
        guard enabled, let deviceToken else { return }
        guard isConfigured else {
            setStatus("Enter your relay's address and secret.", error: true)
            return
        }
        let accounts: [[String: Any]] = MailStore.shared.accounts.compactMap { account in
            guard let password = AccountStorage.password(for: account.id) else { return nil }
            return [
                "id": account.id.uuidString,
                "email": account.email,
                "label": account.label,
                "host": account.imapHost,
                "port": account.imapPort,
                "username": account.loginName,
                "password": password
            ]
        }
        let body: [String: Any] = [
            "device_token": deviceToken,
            "bundle_id": Bundle.main.bundleIdentifier ?? "app.keepwatch.crypt",
            "device_name": UIDevice.current.name,
            "accounts": accounts
        ]
        busy = true
        defer { busy = false }
        do {
            _ = try await post("/register", body: body)
            lastSynced = Date()
            let count = accounts.count
            setStatus("On. The relay is watching \(count) \(count == 1 ? "account" : "accounts").", error: false)
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    func sendTest() async {
        guard let deviceToken else {
            setStatus("No push token yet. Turn notifications on first.", error: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            let reply = try await post("/test", body: ["device_token": deviceToken])
            let env = (reply["environment"] as? String).map { " (\($0))" } ?? ""
            setStatus("Test sent\(env). It should arrive in a few seconds.", error: false)
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func setStatus(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }

    private func baseURL() throws -> URL {
        var text = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text) else { throw MailError.server("The relay address isn't valid.") }
        return url
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try baseURL().appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw MailError.server("Couldn't reach the relay at \(relayURL). Is Tailscale on, and is the relay running?")
        }
        let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw MailError.server("The relay rejected the secret. Check it matches RELAY_SECRET.") }
            let message = json["error"] as? String ?? "HTTP \(code)"
            throw MailError.server("Relay error: \(message)")
        }
        return json
    }
}

/// Receives the push token and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in PushManager.shared.resume() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushManager.shared.didFailToRegister(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let store = MailStore.shared
            if store.currentMailbox?.role == .inbox { await store.refresh() } else { await store.refreshUnreadCounts() }
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let crypt = info["crypt"] as? [String: Any],
           let accountText = crypt["account"] as? String,
           let accountID = UUID(uuidString: accountText) {
            let uid = (crypt["uid"] as? NSNumber)?.uint32Value
            Task { @MainActor in
                await MailStore.shared.openFromNotification(accountID: accountID, uid: uid)
            }
        }
        completionHandler()
    }
}
