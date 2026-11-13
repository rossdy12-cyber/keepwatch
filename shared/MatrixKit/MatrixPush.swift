import SwiftUI
import UIKit
import UserNotifications

/// Push notifications for new messages: Synapse sends them to the relay on the NAS,
/// which forwards them to Apple with your APNs key.
@MainActor
final class MatrixPush: ObservableObject {
    static let shared = MatrixPush()

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "push.enabled") } }
    @Published var relayURL: String { didSet { UserDefaults.standard.set(relayURL, forKey: "push.relay") } }
    @Published private(set) var token: String?
    @Published private(set) var status = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var busy = false
    /// A room to open, set when a notification is tapped.
    @Published var openRoomID: String?

    weak var matrix: MatrixStore?
    private let service = Bundle.main.bundleIdentifier ?? "app.keepwatch"

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "push.enabled")
        relayURL = UserDefaults.standard.string(forKey: "push.relay") ?? ""
    }

    var secret: String {
        get { MatrixKeychain.read(service: service, account: "relay-secret") ?? "" }
        set { MatrixKeychain.save(newValue, service: service, account: "relay-secret"); objectWillChange.send() }
    }

    func resume() {
        if enabled { UIApplication.shared.registerForRemoteNotifications() }
    }

    func turnOn() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            set("Notifications are turned off for this app in iPhone Settings.", error: true)
            return
        }
        enabled = true
        set("Asking Apple for a push token…", error: false)
        UIApplication.shared.registerForRemoteNotifications()
    }

    func turnOff() async {
        enabled = false
        if let token, let api = matrix?.client {
            try? await api.setPusher(["kind": NSNull(), "app_id": service, "pushkey": token])
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        token = nil
        set("Notifications are off.", error: false)
    }

    func didRegister(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        Task { await sync() }
    }

    func didFail(_ error: Error) {
        if error.localizedDescription.contains("aps-environment") {
            set("This copy can't receive push. Install it with Sideloadly using your paid developer Apple ID.", error: true)
        } else {
            set("Apple refused a push token: \(error.localizedDescription)", error: true)
        }
    }

    private var relayBase: URL? { MatrixAPI.normalize(relayURL) }

    /// Registers this iPhone with the relay, then asks Synapse to push to the relay.
    func sync() async {
        guard enabled, let token, let api = matrix?.client else { return }
        guard let relayBase, !secret.isEmpty else {
            set("Enter the relay's address and secret.", error: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: relayBase.appendingPathComponent("register"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_token": token, "bundle_id": service, "device_name": UIDevice.current.name, "accounts": [Any]()
            ])
            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: request)
            } catch {
                throw MatrixError.unreachable(relayURL)
            }
            let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw MatrixError.server(code: "401", message: "The relay rejected the secret. Check it matches RELAY_SECRET.", status: 401) }
            guard (200..<300).contains(code) else {
                let message = ((try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any])?["error"] as? String
                throw MatrixError.server(code: "\(code)", message: "Relay error: \(message ?? "HTTP \(code)")", status: code)
            }
            try await api.setPusher([
                "kind": "http",
                "app_id": service,
                "pushkey": token,
                "app_display_name": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Crypt",
                "device_display_name": UIDevice.current.name,
                "lang": "en",
                "data": ["url": relayBase.appendingPathComponent("_matrix/push/v1/notify").absoluteString],
                "append": false
            ])
            set("On. New messages will be pushed to this iPhone.", error: false)
        } catch {
            set(error.localizedDescription, error: true)
        }
    }

    func sendTest() async {
        guard let token, let relayBase else { return }
        var request = URLRequest(url: relayBase.appendingPathComponent("test"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_token": token])
        if let result = try? await URLSession.shared.data(for: request), (result.1 as? HTTPURLResponse)?.statusCode == 200 {
            set("Test sent. It should arrive in a few seconds.", error: false)
        } else {
            set("The relay couldn't send the test. Check its logs.", error: true)
        }
    }

    private func set(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

final class MatrixAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in MatrixPush.shared.resume() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in MatrixPush.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in MatrixPush.shared.didFail(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app is open and syncing already; just show a banner.
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let matrix = response.notification.request.content.userInfo["matrix"] as? [String: Any], let room = matrix["room_id"] as? String {
            Task { @MainActor in MatrixPush.shared.openRoomID = room }
        }
        completionHandler()
    }
}

/// The settings screen for push notifications.
struct PushSettingsView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @ObservedObject private var push = MatrixPush.shared
    @State private var relay = ""
    @State private var secret = ""

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Tidings").font(Theme.gothic(40)).foregroundStyle(Theme.bone)
                    Text("New messages are pushed through the crypt-relay on your NAS, the same relay Crypt uses for mail. It needs your paid developer account's APNs key.")
                        .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                    InscribedField(label: "Relay address", text: $relay, prompt: "http://100.x.y.z:8787", keyboard: .URL)
                    InscribedField(label: "Relay secret", text: $secret, prompt: "RELAY_SECRET", secure: true)
                    if push.enabled {
                        Button("Save and reconnect") { save(); Task { await push.sync() } }
                            .buttonStyle(CrimsonButtonStyle())
                        Button("Send a test notification") { Task { await push.sendTest() } }
                            .buttonStyle(CrimsonButtonStyle(filled: false))
                        Button("Turn off notifications") { Task { await push.turnOff() } }
                            .buttonStyle(CrimsonButtonStyle(filled: false))
                    } else {
                        Button("Turn on notifications") { save(); Task { await push.turnOn() } }
                            .buttonStyle(CrimsonButtonStyle())
                            .disabled(relay.isEmpty || secret.isEmpty)
                    }
                    if push.busy { ProgressView().tint(Theme.blood).frame(maxWidth: .infinity) }
                    if !push.status.isEmpty {
                        Label(push.status, systemImage: push.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(Theme.serif(15))
                            .foregroundStyle(push.statusIsError ? Theme.ember : Theme.bone)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            push.matrix = matrix
            relay = push.relayURL
            secret = push.secret
        }
    }

    private func save() {
        push.matrix = matrix
        push.relayURL = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        push.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
