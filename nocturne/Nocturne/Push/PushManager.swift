import SwiftUI
import UserNotifications
import UIKit

/// Registers this device's APNs token with jarvis-core so the other person's messages/calls push to it natively.
final class PushManager {
    static let shared = PushManager()
    private(set) var deviceToken: String?

    func register(token: String) {
        deviceToken = token
        send()
    }

    /// Re-post the token with the current room/name (call when settings or the active room may have changed).
    func reregister() { send() }

    private func send() {
        guard let token = deviceToken else { return }
        let defaults = UserDefaults.standard
        let base = ServerAddress.normalize(defaults.string(forKey: "relayURL") ?? "")
        guard !base.isEmpty, let url = URL(string: base + "/api/push/register") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authToken = defaults.string(forKey: "relayToken") ?? ""
        if !authToken.isEmpty { request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "token": token,
            "room": defaults.string(forKey: "chatRoom") ?? "home",
            "name": defaults.string(forKey: "displayName") ?? "Me",
            "platform": "ios",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        netSession.dataTask(with: request).resume()
    }
}

/// Wires up notifications: asks permission, registers for APNs, forwards the token, and routes taps to deep links.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushManager.shared.register(token: hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Fires on a build whose signing profile has no push entitlement — nothing to do, chat still works.
    }

    // Show the banner even when Nocturne is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapping a push opens its deep link (nocturne://chat/… or nocturne://call/…).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let string = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: string) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        completionHandler()
    }
}
