import SwiftUI

/// Routes `sentrycam://event/<id>` and `sentrycam://camera/<name>` (from a Frigate push or the widget).
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var eventID: String?
    @Published var camera: String?

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "sentrycam" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "event": eventID = parts.first
        case "camera": camera = parts.first?.removingPercentEncoding
        default: break
        }
    }
}

@main
struct SentryCamApp: App {
    @StateObject private var settings = FrigateSettings.shared
    @StateObject private var store = FrigateStore()
    @StateObject private var router = DeepLinkRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { router.handle($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var settings: FrigateSettings
    @EnvironmentObject private var store: FrigateStore
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiveView().tabItem { Label("Live", systemImage: "video.fill") }.tag(0)
            EventsView().tabItem { Label("Events", systemImage: "figure.walk.motion") }.tag(1)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .task(id: settings.address + settings.username) { await store.start(settings) }
        .onAppear { if !settings.isConfigured { tab = 2 } }
        .onChange(of: router.eventID) { if $0 != nil { tab = 1 } }
        .onChange(of: router.camera) { if $0 != nil { tab = 0 } }
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
