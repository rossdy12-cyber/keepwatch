import SwiftUI

@main
struct ReliquaryApp: App {
    @StateObject private var store = GalleryStore()

    init() {
        Theme.configureAppearance()
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = Theme.uiVoid
        tab.shadowColor = UIColor(red: 0.26, green: 0.09, blue: 0.12, alpha: 1)
        let item = UITabBarItemAppearance()
        let font = UIFont(name: "Cinzel-Regular", size: 10) ?? .systemFont(ofSize: 10)
        item.normal.titleTextAttributes = [.font: font, .foregroundColor: UIColor(red: 0.62, green: 0.55, blue: 0.53, alpha: 1)]
        item.normal.iconColor = UIColor(red: 0.62, green: 0.55, blue: 0.53, alpha: 1)
        item.selected.titleTextAttributes = [.font: font, .foregroundColor: Theme.uiBlood]
        item.selected.iconColor = Theme.uiBlood
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isConfigured {
                    MainTabs()
                } else {
                    SetupView()
                }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.blood)
            .animation(.easeInOut(duration: 0.4), value: store.isConfigured)
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var store: GalleryStore

    var body: some View {
        TabView {
            ChronicleView()
                .tabItem { Label("Chronicle", systemImage: "hourglass") }
            CatacombsView()
                .tabItem { Label("Catacombs", systemImage: "building.columns") }
            RelicsView()
                .tabItem { Label("Relics", systemImage: "heart") }
            SanctumView()
                .tabItem { Label("Sanctum", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) {
            if let message = store.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.ember)
                    Text(message)
                        .font(Theme.serif(15))
                        .foregroundStyle(Theme.bone)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(Theme.ash)
                    }
                }
                .padding(14)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
                .padding(.horizontal)
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: store.errorMessage)
    }
}
