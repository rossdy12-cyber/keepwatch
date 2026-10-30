import SwiftUI
import UIKit

enum Theme {
    /// Keepwatch teal.
    static let accent = Color(red: 0.20, green: 0.84, blue: 0.76)
    static let background = Color(red: 0.035, green: 0.043, blue: 0.06)
    static let surface = Color(red: 0.09, green: 0.105, blue: 0.13)
    static let surfaceRaised = Color(red: 0.13, green: 0.15, blue: 0.18)
    static let secondaryText = Color(white: 0.6)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let download = Color(red: 0.36, green: 0.62, blue: 1.0)

    static func color(for service: Service) -> Color {
        switch service {
        case .truenas: return accent
        case .nzbget: return Color(red: 0.36, green: 0.75, blue: 0.35)
        case .sonarr: return Color(red: 0.2, green: 0.67, blue: 0.96)
        case .radarr: return Color(red: 1.0, green: 0.76, blue: 0.2)
        case .lidarr: return Color(red: 0.4, green: 0.82, blue: 0.5)
        }
    }

    /// Green under 70 %, amber under 90 %, red above.
    static func level(_ fraction: Double) -> Color {
        fraction < 0.7 ? good : (fraction < 0.9 ? warning : danger)
    }

    static func temperatureColor(_ celsius: Double?) -> Color {
        guard let celsius else { return secondaryText }
        return celsius < 50 ? good : (celsius < 65 ? warning : danger)
    }

    @MainActor
    static func applyUIKitAppearance() {
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
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
