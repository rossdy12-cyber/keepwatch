import SwiftUI

struct RootView: View {
    var body: some View {
        LinkListView()
    }
}

#Preview {
    RootView()
        .environmentObject(LinkStore())
}
