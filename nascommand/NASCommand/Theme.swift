import SwiftUI

enum Theme {
    static let accent = Color(red: 0.19, green: 0.55, blue: 0.95)
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let surface = Color(red: 0.12, green: 0.13, blue: 0.16)
    static let secondaryText = Color(white: 0.62)
    static let good = Color(red: 0.26, green: 0.78, blue: 0.45)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.20)
    static let danger = Color(red: 0.93, green: 0.33, blue: 0.33)

    /// Colour for a pool/app status word.
    static func statusColor(_ status: String?) -> Color {
        switch (status ?? "").uppercased() {
        case "ONLINE", "RUNNING", "HEALTHY", "ACTIVE": return good
        case "DEPLOYING", "STARTING", "STOPPING", "PENDING": return warning
        case "DEGRADED", "STOPPED", "CRASHED", "FAULTED", "OFFLINE", "ERROR", "UNHEALTHY": return danger
        default: return secondaryText
        }
    }
}
