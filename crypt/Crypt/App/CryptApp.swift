import SwiftUI

@main
struct CryptApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MailStore.shared
    @StateObject private var push = PushManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(push)
                .preferredColorScheme(.dark)
                .tint(Theme.blood)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.hasAccounts, store.currentMailbox != nil {
                Task { await store.refresh() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: MailStore

    var body: some View {
        Group {
            if !store.hasAccounts {
                SetupView()
            } else {
                InboxView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: store.hasAccounts)
    }
}
