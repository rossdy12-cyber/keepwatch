import SwiftUI
import UIKit

enum Theme {
    /// Jarvis blue.
    static let accent = Color(red: 0.36, green: 0.78, blue: 1.0)
    static let background = Color(red: 0.024, green: 0.04, blue: 0.07)
    static let surface = Color(red: 0.07, green: 0.10, blue: 0.15)
    static let surfaceRaised = Color(red: 0.11, green: 0.15, blue: 0.21)
    static let userBubble = Color(red: 0.13, green: 0.40, blue: 0.62)
    static let secondaryText = Color(white: 0.6)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    @MainActor
    static func applyUIKitAppearance() {
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1)
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
