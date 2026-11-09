import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        Group {
            if !auth.isAuthenticated {
                ServerSetupView()
            } else if !auth.isUnlocked {
                FaceIDGateView()
            } else if let client = auth.client {
                LibraryView(client: client)
            } else {
                ServerSetupView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auth.isAuthenticated)
        .animation(.easeInOut(duration: 0.2), value: auth.isUnlocked)
    }
}
