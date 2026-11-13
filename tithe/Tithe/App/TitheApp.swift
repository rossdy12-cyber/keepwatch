import SwiftUI

@main
struct TitheApp: App {
    @StateObject private var store = TitheStore()
    @Environment(\.scenePhase) private var phase

    init() {
        Theme.configureAppearance()
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = Theme.uiVoid
        let item = UITabBarItemAppearance()
        let font = UIFont(name: "Cinzel-Regular", size: 10) ?? .systemFont(ofSize: 10)
        let ash = UIColor(red: 0.62, green: 0.55, blue: 0.53, alpha: 1)
        item.normal.titleTextAttributes = [.font: font, .foregroundColor: ash]
        item.normal.iconColor = ash
        item.selected.titleTextAttributes = [.font: font, .foregroundColor: Theme.uiBlood]
        item.selected.iconColor = Theme.uiBlood
        tab.stackedLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                OfferingsView()
                    .tabItem { Label("Offerings", systemImage: "flame") }
                SeekView()
                    .tabItem { Label("Seek", systemImage: "magnifyingglass") }
                VigilView()
                    .tabItem { Label("Vigil", systemImage: "eye") }
                    .badge(store.watchlist.filter(\.isHit).count)
                SanctumView()
                    .tabItem { Label("Sanctum", systemImage: "gearshape") }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.blood)
            .task { await store.start() }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await store.refreshWatchlist() } }
        }
        .backgroundTask(.appRefresh(TitheStore.refreshID)) {
            TitheStore.scheduleRefresh()
            await TitheStore.backgroundCheck()
        }
    }
}

