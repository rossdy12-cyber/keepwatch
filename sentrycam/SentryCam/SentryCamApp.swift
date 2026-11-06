import SwiftUI

@main
struct SentryCamApp: App {
    @StateObject private var settings = FrigateSettings.shared
    @StateObject private var store = FrigateStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var settings: FrigateSettings
    @EnvironmentObject private var store: FrigateStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiveView().tabItem { Label("Live", systemImage: "video.fill") }.tag(0)
            EventsView().tabItem { Label("Events", systemImage: "figure.walk.motion") }.tag(1)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .task(id: settings.address + settings.username) { await store.start(settings) }
        .onAppear { if !settings.isConfigured { tab = 2 } }
    }
}

/// Shown on Live/Events when nothing is set up yet.
struct ConfigurePrompt: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.badge.ellipsis").font(.system(size: 42)).foregroundStyle(Theme.secondaryText)
            Text("Connect to Frigate").font(.headline)
            Text("Add your Frigate address (and login) in the Settings tab.")
                .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
