import SwiftUI

struct LinkVaultEmbeddedHostView: View {
    @StateObject private var linkStore = LVLinkStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LVRootView()
            .environmentObject(linkStore)
            .task { linkStore.importPendingSharedURLs() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { linkStore.importPendingSharedURLs() }
            }
    }
}
