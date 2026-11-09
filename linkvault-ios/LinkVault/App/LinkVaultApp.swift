import SwiftUI

@main
struct LinkVaultApp: App {
    @StateObject private var linkStore = LinkStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(linkStore)
                .task { linkStore.importPendingSharedURLs() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { linkStore.importPendingSharedURLs() }
                }
        }
    }
}
