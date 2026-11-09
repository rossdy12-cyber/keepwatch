import SwiftUI

struct MediaPipeEmbeddedHostView: View {
    @StateObject private var settings = MPAppSettings()
    @StateObject private var router = MPAppRouter()

    var body: some View {
        MPRootView()
            .environmentObject(settings)
            .environmentObject(router)
            .onAppear {
                loadPendingSharedURL()
            }
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
