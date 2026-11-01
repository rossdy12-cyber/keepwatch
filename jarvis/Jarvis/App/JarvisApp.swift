import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var settings = JarvisSettings()
    @StateObject private var chat = ChatStore()
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
