import SwiftUI
import UIKit

/// Crimson's palette: deep black with blood-crimson accents.
enum Crimson {
    static let bg = Color(hex: "0A0506")
    static let bg2 = Color(hex: "140a0c")
    static let panel = Color(hex: "1A1013")
    static let field = Color(hex: "241319")
    static let accent = Color(hex: "C01030")
    static let accent2 = Color(hex: "E8415C")
    static let text = Color(hex: "F0E6E8")
    static let muted = Color(hex: "9A8288")
    static let hairline = Color.white.opacity(0.08)
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255,
                  opacity: 1)
    }
}
