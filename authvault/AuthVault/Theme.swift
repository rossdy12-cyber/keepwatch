import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.68, blue: 0.98)
    static let background = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let surface = Color(white: 0.13)
    static let secondaryText = Color(white: 0.62)
    static let good = Color(red: 0.26, green: 0.78, blue: 0.45)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.20)

    /// Code goes amber then red as the step runs out.
    static func countdownColor(_ remaining: Int, period: Int) -> Color {
        let frac = Double(remaining) / Double(max(period, 1))
        if frac <= 0.15 { return warning }
        return accent
    }
}

extension String {
    /// "123456" -> "123 456", "12345678" -> "1234 5678"
    var groupedCode: String {
        let chars = Array(self)
        guard chars.count == 6 || chars.count == 8 else { return self }
        let mid = chars.count / 2
        return String(chars[..<mid]) + " " + String(chars[mid...])
    }
}
