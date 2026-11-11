import SwiftUI
import UIKit

// The building blocks a user picks to design their companion creature.

enum BodyShape: String, Codable, CaseIterable, Identifiable {
    case round, egg, bean, chonk
    var id: String { rawValue }
}

enum EyeStyle: String, Codable, CaseIterable, Identifiable {
    case round, happy, sleepy, sparkle
    var id: String { rawValue }
}

enum MouthStyle: String, Codable, CaseIterable, Identifiable {
    case smile, cat, neutral, open
    var id: String { rawValue }
}

enum Accessory: String, Codable, CaseIterable, Identifiable {
    case none, antennae, bow, cap, flower, headphones
    var id: String { rawValue }
    var label: String { self == .none ? "None" : rawValue.capitalized }
}

/// How the creature is behaving right now (drives its animation).
enum CreatureActivity { case idle, talking, listening }

/// A nice default palette of companion colours.
enum Palette {
    static let bodies: [String] = [
        "7FB2F0", "9D7FF0", "F08FC2", "F0A868", "7FD0A8", "E86A6A",
        "68C3D4", "C0D06A", "B08968", "9AA7B3", "EAC84F", "6A8CF0",
    ]
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255; b = Double(v & 0xff) / 255
        } else { r = 0.6; g = 0.7; b = 0.9 }
        self.init(red: r, green: g, blue: b)
    }

    /// A lighter tint for the belly/highlights.
    func lightened(_ amount: Double = 0.35) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        return Color(hue: Double(h), saturation: Double(max(0, s - 0.25)), brightness: Double(min(1, br + amount)))
    }
}
