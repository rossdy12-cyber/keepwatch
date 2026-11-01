import SwiftUI
import UserNotifications

@main
struct JarvisApp: App {
    @StateObject private var settings = JarvisSettings.shared
    @StateObject private var chat = ChatStore.shared
    @StateObject private var speaker = Speaker()

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(chat)
                .environmentObject(speaker)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    // Slow Siri answers arrive as notifications.
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    // Work out the core's API now, so the first Siri request doesn't have to.
                    if settings.config.style == .auto && settings.detection == nil {
                        settings.detection = try? await settings.client.detect()
                    }
                }
        }
    }
}

enum AppTab: Hashable {
    case chat, settings
}

struct RootView: View {
    @EnvironmentObject private var settings: JarvisSettings
    @State private var tab: AppTab = .chat

    var body: some View {
        TabView(selection: $tab) {
            ChatView(openSettings: { tab = .settings })
                .tabItem { Label("Jarvis", systemImage: "waveform.circle") }
                .tag(AppTab.chat)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onAppear {
            if !settings.isConfigured { tab = .settings }
        }
    }
}
