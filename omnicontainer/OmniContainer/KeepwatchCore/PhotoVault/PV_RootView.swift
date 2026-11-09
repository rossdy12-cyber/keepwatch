import SwiftUI

struct PVRootView: View {
    @EnvironmentObject private var auth: PVAuthViewModel

    var body: some View {
        Group {
            if !auth.isAuthenticated {
                PVServerSetupView()
            } else if !auth.isUnlocked {
                PVFaceIDGateView()
            } else if let client = auth.client {
                PVLibraryView(client: client)
            } else {
                PVServerSetupView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auth.isAuthenticated)
        .animation(.easeInOut(duration: 0.2), value: auth.isUnlocked)
    }
}
