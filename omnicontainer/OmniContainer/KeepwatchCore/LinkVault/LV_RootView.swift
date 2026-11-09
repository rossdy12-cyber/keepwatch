import SwiftUI

struct LVRootView: View {
    var body: some View {
        LVLinkListView()
    }
}

#Preview {
    LVRootView()
        .environmentObject(LVLinkStore())
}
