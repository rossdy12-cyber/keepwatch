import SwiftUI

@main
struct CryptApp: App {
    @StateObject private var store = MailStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.blood)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.account != nil, store.currentMailbox != nil {
                Task { await store.refresh() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        Group {
            if store.account == nil {
                SetupView()
            } else {
                InboxView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: store.account == nil)
    }
}
