import SwiftUI

@main
struct KithApp: App {
    @StateObject private var store = CompanionStore()
    @StateObject private var settings = KithSettings.shared
    @StateObject private var speaker = Speaker()

    var body: some Scene {
        WindowGroup {
            CompanionsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(speaker)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
