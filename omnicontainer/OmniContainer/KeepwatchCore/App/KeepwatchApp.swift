import SwiftUI
import UserNotifications

struct KeepwatchStandaloneApp: App {
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

            PaydaysView()
                .tabItem { Label("Paydays", systemImage: "sterlingsign.circle") }
                .tag(AppTab.paydays)

            HubView()
                .tabItem { Label("Chronicle", systemImage: "sparkles.rectangle.stack") }
                .tag(AppTab.hub)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}


// MARK: - Dedicated Native Hosts for OmniContainer (Zero Duplication!)

struct KeepwatchEmbeddedHostView: View {
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

    var body: some View {
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
    }
}

struct NativeJarvisEmbeddedView: View {
    @StateObject private var settings = ServiceSettings()
    @StateObject private var router = AppRouter()
    @StateObject private var jarvisSettings = JarvisSettings.shared
    @StateObject private var chat = ChatStore.shared
    @StateObject private var speaker = Speaker()
    @StateObject private var bridge = HomelabBridgeStore.shared
    @State private var showSettingsSheet = false

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some View {
        ChatView(openSettings: { showSettingsSheet = true })
            .environmentObject(settings)
            .environmentObject(router)
            .environmentObject(jarvisSettings)
            .environmentObject(chat)
            .environmentObject(speaker)
            .environmentObject(bridge)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .sheet(isPresented: $showSettingsSheet) {
                NavigationStack {
                    Form {
                        JarvisSettingsSections()
                    }
                    .scrollContentBackground(.hidden)
                    .keepwatchChrome()
                    .navigationTitle("Jarvis & Voice Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettingsSheet = false }
                        }
                    }
                }
                .environmentObject(jarvisSettings)
                .environmentObject(chat)
                .environmentObject(speaker)
                .preferredColorScheme(.dark)
            }
            .task {
                if jarvisSettings.config.style == .auto && jarvisSettings.detection == nil {
                    jarvisSettings.detection = try? await jarvisSettings.client.detect()
                }
            }
    }
}

struct NativeNASPortalEmbeddedView: View {
    @StateObject private var portal = PortalStore()
    @State private var mode = 0

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Portal Mode", selection: $mode) {
                Text("SSL Apps Grid").tag(0)
                Text("2FA Vault").tag(1)
                Text("Vaultwarden").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.background)

            if mode == 0 {
                SitesView()
                    .environmentObject(portal)
            } else if mode == 1 {
                NavigationStack {
                    Form {
                        OTPSection()
                            .listRowBackground(Theme.surface)
                        PortalExtraSection()
                    }
                    .scrollContentBackground(.hidden)
                    .keepwatchChrome()
                    .navigationTitle("2FA Authenticator & Vault")
                }
                .environmentObject(portal)
            } else {
                FastCachedWebView(cacheKey: "np-vaultwarden-ssl", urlString: "https://vw.nas-server.co.uk")
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

struct NativeRaceboltEmbeddedView: View {
    @StateObject private var hub = HubStore.shared
    @StateObject private var settings = ServiceSettings()
    @StateObject private var router = AppRouter()
    @State private var mode = 0

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Racebolt View", selection: $mode) {
                Text("SKU & Stock Ops").tag(0)
                Text("Live Storefront (SSL)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.background)

            if mode == 0 {
                HubView(lockedSection: .store)
                    .environmentObject(hub)
                    .environmentObject(settings)
                    .environmentObject(router)
            } else {
                FastCachedWebView(cacheKey: "racebolt-live-ssl", urlString: "https://raceboltuk.com")
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
