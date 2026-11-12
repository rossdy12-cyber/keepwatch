import SwiftUI

@main
struct CrimsonApp: App {
    @StateObject private var store = BrowserStore()
    @StateObject private var scripts = UserScriptStore.shared

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(store)
                .environmentObject(scripts)
                .preferredColorScheme(.dark)
                .tint(Crimson.accent)
        }
    }
}
