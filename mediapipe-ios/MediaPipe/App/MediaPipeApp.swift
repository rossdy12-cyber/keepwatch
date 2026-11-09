import SwiftUI

@main
struct MediaPipeApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(router)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    loadPendingSharedURL()
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "mediapipe", url.host == "add" else {
            return
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let rawURL = queryItems.first(where: { $0.name == "url" })?.value,
              let sharedURL = URL(string: rawURL) else {
            return
        }

        router.selectedTab = 1
        router.pendingShareURL = sharedURL
    }

    private func loadPendingSharedURL() {
        guard let defaults = UserDefaults(suiteName: "group.uk.co.rossdymond.mediapipe"),
              let rawURL = defaults.string(forKey: "pendingShareURL"),
              let sharedURL = URL(string: rawURL) else {
            return
        }

        defaults.removeObject(forKey: "pendingShareURL")
        router.selectedTab = 1
        router.pendingShareURL = sharedURL
    }
}
