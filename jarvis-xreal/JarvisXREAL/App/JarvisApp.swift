import SwiftUI
import UserNotifications

@main
struct JarvisXREALApp: App {
    @StateObject private var settings = JarvisSettings.shared
    @StateObject private var chat = ChatStore.shared
    @StateObject private var speaker = Speaker()
    @StateObject private var xreal = XRealDisplayManager.shared
    @StateObject private var telemetry = ARTelemetryStore.shared

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(chat)
                .environmentObject(speaker)
                .environmentObject(xreal)
                .environmentObject(telemetry)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    xreal.checkScreens()
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    if settings.config.style == .auto && settings.detection == nil {
                        settings.detection = try? await settings.client.detect()
                    }
                    await telemetry.refreshAll()
                }
        }
    }
}

enum AppTab: Hashable {
    case visor, chat, settings
}

struct RootView: View {
    @EnvironmentObject private var settings: JarvisSettings
    @State private var tab: AppTab = .visor

    var body: some View {
        TabView(selection: $tab) {
            XRealCockpitView(openSettings: { tab = .settings })
                .tabItem { Label("AR Visor", systemImage: "eyeglasses") }
                .tag(AppTab.visor)

            ChatView(openSettings: { tab = .settings })
                .tabItem { Label("Jarvis Chat", systemImage: "waveform.circle") }
                .tag(AppTab.chat)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
