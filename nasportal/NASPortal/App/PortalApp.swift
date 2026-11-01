import SwiftUI
import UIKit

@main
struct PortalApp: App {
    @StateObject private var store = PortalStore()

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum PortalTab: Hashable {
    case truenas, apps, settings
}

struct RootView: View {
    @EnvironmentObject private var store: PortalStore
    @State private var tab: PortalTab = .truenas

    var body: some View {
        TabView(selection: $tab) {
            TrueNASTab()
                .tabItem { Label("TrueNAS", systemImage: "server.rack") }
                .tag(PortalTab.truenas)
            SitesView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(PortalTab.apps)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(PortalTab.settings)
        }
        .onAppear {
            if store.trueNASURL == nil { tab = .settings }
        }
    }
}

/// The TrueNAS web interface, always loaded and ready in the first tab.
struct TrueNASTab: View {
    @EnvironmentObject private var store: PortalStore

    var body: some View {
        if let url = store.trueNASURL {
            WebScreen(destination: WebDestination(title: "TrueNAS", url: url), showsDone: false)
                .id(url)
        } else {
            NavigationStack {
                MessageCard(symbol: "server.rack", title: "Add your TrueNAS address",
                            message: "Enter it in Settings, for example https://nas-server.co.uk or https://100.x.x.x")
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .portalChrome()
                    .navigationTitle("TrueNAS")
            }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.275, green: 0.843, blue: 0.765)
    static let background = Color(red: 0.03, green: 0.055, blue: 0.086)
    static let surface = Color(red: 0.085, green: 0.12, blue: 0.16)
    static let secondaryText = Color(white: 0.6)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)

    @MainActor
    static func applyUIKitAppearance() {
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.07, alpha: 1)
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor = UIColor(Theme.background)
        navBar.shadowColor = .clear
        navBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navBar.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navBar
        UINavigationBar.appearance().compactAppearance = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar
    }
}

struct PortalChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.background.ignoresSafeArea())
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    func portalChrome() -> some View {
        modifier(PortalChrome())
    }
}

struct MessageCard: View {
    var symbol: String
    var title: String
    var message: String
    var color: Color = Theme.accent
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
