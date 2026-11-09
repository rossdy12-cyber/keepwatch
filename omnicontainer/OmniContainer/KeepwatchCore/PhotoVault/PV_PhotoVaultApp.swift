import SwiftUI

struct PhotoVaultEmbeddedHostView: View {
    @StateObject private var auth = PVAuthViewModel()

    var body: some View {
        PVRootView()
            .environmentObject(auth)
    }
}
