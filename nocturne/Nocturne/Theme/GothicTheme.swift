import SwiftUI
import UIKit

/// A gothic colour scheme. Every Nocturne module renders from the active theme,
/// so switching it re-skins Phone, Messages, Clock, etc. all at once.
struct GothicTheme: Identifiable, Equatable, Codable {
    var id: String { name }
    let name: String
    let bg: [String]      // deep background gradient (top -> bottom)
    let panel: String     // card / surface colour
    let accent: String    // primary accent (blood, amethyst, ...)
    let accent2: String   // secondary accent
    let text: String
    let muted: String

    var bgColors: [Color] { bg.map { Color(hex: $0) } }
    var panelColor: Color { Color(hex: panel) }
    var accentColor: Color { Color(hex: accent) }
    var accent2Color: Color { Color(hex: accent2) }
    var textColor: Color { Color(hex: text) }
    var mutedColor: Color { Color(hex: muted) }
}

enum GothicThemes {
    static let all: [GothicTheme] = [
        GothicTheme(name: "Vampire", bg: ["050203", "1C060B", "030102"], panel: "120609",
                    accent: "D4163A", accent2: "FF6B81", text: "EFE4E1", muted: "9C8589"),
        GothicTheme(name: "Crimson Vigil", bg: ["0B0608", "1A0A0E", "070406"], panel: "1C1116",
                    accent: "B01030", accent2: "E04050", text: "EDE3E6", muted: "8A7076"),
        GothicTheme(name: "Amethyst Mourning", bg: ["0A0710", "160B22", "060410"], panel: "19122A",
                    accent: "8A3FD1", accent2: "C07BFF", text: "E9E2F2", muted: "8A7CA0"),
        GothicTheme(name: "Obsidian", bg: ["070708", "121214", "050506"], panel: "17181B",
                    accent: "9AA0AA", accent2: "D5DAE2", text: "E6E8EC", muted: "767A82"),
        GothicTheme(name: "Nightshade", bg: ["05090A", "0A1618", "040809"], panel: "0F1C1E",
                    accent: "1E8F7E", accent2: "4FE0C6", text: "DFEDEA", muted: "6F8A85"),
        GothicTheme(name: "Ember", bg: ["0C0704", "1C0E05", "080503"], panel: "1E130B",
                    accent: "C8641A", accent2: "F2A23E", text: "F0E6DA", muted: "95816E"),
    ]
    static var `default`: GothicTheme { all[0] }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Deep vertical gothic gradient with a faint vignette.
struct GothicBackground: View {
    let theme: GothicTheme
    var body: some View {
        ZStack {
            LinearGradient(colors: theme.bgColors, startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 120, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// A gothic serif title.
struct GothicTitle: View {
    let text: String
    var theme: GothicTheme
    var size: CGFloat = 30
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .serif))
            .foregroundStyle(theme.textColor)
            .shadow(color: theme.accentColor.opacity(0.4), radius: 8)
    }
}

/// A raised surface with a hairline accent border — the suite's card.
struct GothicCard<Content: View>: View {
    var theme: GothicTheme
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.panelColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.35), lineWidth: 1)
            )
    }
}

/// A thin filigree divider (ornament between sections).
struct Filigree: View {
    var theme: GothicTheme
    var body: some View {
        HStack(spacing: 8) {
            line
            Image(systemName: "seal")
                .font(.system(size: 10))
                .foregroundStyle(theme.accentColor)
            line
        }
        .foregroundStyle(theme.accentColor.opacity(0.4))
    }
    private var line: some View {
        Rectangle().fill(
            LinearGradient(colors: [.clear, theme.accentColor.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
        ).frame(height: 1)
    }
}
