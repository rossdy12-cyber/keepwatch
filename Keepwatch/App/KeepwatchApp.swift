import SwiftUI
import UserNotifications

@main
struct KeepwatchApp: App {
    @StateObject private var settings = ServiceSettings()
    @StateObject private var truenas = TrueNASStore()
    @StateObject private var media = MediaStore()
    @StateObject private var router = AppRouter()
    @StateObject private var jarvisSettings = JarvisSettings.shared
    @StateObject private var chat = ChatStore.shared
    @StateObject private var speaker = Speaker()
    @StateObject private var portal = PortalStore()
    @StateObject private var paydays = PaydaysStore.shared
    @StateObject private var hub = HubStore.shared
    @StateObject private var bridge = HomelabBridgeStore.shared

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(truenas)
                .environmentObject(media)
                .environmentObject(router)
                .environmentObject(jarvisSettings)
                .environmentObject(chat)
                .environmentObject(speaker)
                .environmentObject(portal)
                .environmentObject(paydays)
                .environmentObject(hub)
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    if jarvisSettings.config.style == .auto && jarvisSettings.detection == nil {
                        jarvisSettings.detection = try? await jarvisSettings.client.detect()
                    }
                }
        }
    }
}

enum AppTab: Hashable {
    case command, jarvis, paydays, hub, settings
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .command
    @Published var commandSubTab: CommandSubTab = .pulse
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var jarvisSettings: JarvisSettings
    @EnvironmentObject private var paydays: PaydaysStore

    var body: some View {
        TabView(selection: $router.tab) {
            CommandCenterView()
                .tabItem { Label("Homelab", systemImage: "server.rack") }
                .tag(AppTab.command)

            ChatView(openSettings: { router.tab = .settings })
                .tabItem { Label("Jarvis", systemImage: "waveform.circle") }
                .tag(AppTab.jarvis)

            PaydaysView()
                .tabItem { Label("Paydays", systemImage: "sterlingsign.circle") }
                .tag(AppTab.paydays)

            HubView()
                .tabItem { Label("Hub", systemImage: "sparkles.rectangle.stack") }
                .tag(AppTab.hub)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
