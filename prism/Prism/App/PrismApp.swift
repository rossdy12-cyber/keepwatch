import SwiftUI

@main
struct PrismApp: App {
    @StateObject private var store = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(store.selected.accentColor)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: ThemeStore

    var body: some View {
        TabView {
            ThemesView()
                .tabItem { Label("Themes", systemImage: "paintpalette.fill") }
            WallpaperView()
                .tabItem { Label("Wallpaper", systemImage: "photo.fill") }
            IconsView()
                .tabItem { Label("Icons", systemImage: "app.badge.fill") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle.fill") }
        }
    }
}

// build: force prism-only rebuild to capture compiler log
