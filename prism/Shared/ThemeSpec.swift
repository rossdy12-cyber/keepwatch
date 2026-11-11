import SwiftUI
import UIKit

enum ThemeStyle: String, Codable, CaseIterable, Identifiable {
    case gradient, solid, aurora, bands
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A theme: a palette + a style. Everything (wallpapers, icons, widgets) is rendered from this.
struct ThemeSpec: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var colors: [String]     // 1–4 hex colours
    var accent: String       // glyph / highlight colour
    var style: ThemeStyle
    var lightText: Bool = true

    var swatchColors: [Color] { colors.map { Color(hex: $0) } }
    var accentColor: Color { Color(hex: accent) }
    var textColor: Color { lightText ? .white : .black }
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
    func hexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}

/// Renders a theme as a full-bleed background. Used for wallpapers, icon tiles and widgets.
struct ThemeBackground: View {
    let spec: ThemeSpec

    var body: some View {
        let cols = spec.colors.isEmpty ? [Color.black] : spec.swatchColors
        GeometryReader { geo in
            ZStack {
                switch spec.style {
                case .solid:
                    cols[0]
                case .gradient:
                    LinearGradient(colors: cols, startPoint: .topLeading, endPoint: .bottomTrailing)
                case .bands:
                    LinearGradient(stops: bandStops(cols), startPoint: .top, endPoint: .bottom)
                case .aurora:
                    cols[0]
                    ForEach(Array(cols.enumerated()), id: \.offset) { i, color in
                        let p = auroraPoints[i % auroraPoints.count]
                        RadialGradient(colors: [color.opacity(0.95), color.opacity(0)],
                                       center: .init(x: p.x, y: p.y),
                                       startRadius: 0, endRadius: geo.size.width * 0.9)
                    }
                    .blur(radius: geo.size.width * 0.02)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private let auroraPoints: [CGPoint] = [
        .init(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.3), .init(x: 0.3, y: 0.8), .init(x: 0.85, y: 0.85),
    ]

    private func bandStops(_ cols: [Color]) -> [Gradient.Stop] {
        guard cols.count > 1 else { return [.init(color: cols[0], location: 0), .init(color: cols[0], location: 1)] }
        var stops: [Gradient.Stop] = []
        let n = cols.count
        for (i, c) in cols.enumerated() {
            let lo = Double(i) / Double(n)
            let hi = Double(i + 1) / Double(n)
            stops.append(.init(color: c, location: lo))
            stops.append(.init(color: c, location: hi))
        }
        return stops
    }
}

/// The selected theme, shared with the widget via an App Group.
enum ThemeStorage {
    static let appGroup = "group.app.prism"
    private static let key = "selectedTheme"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func saveSelected(_ spec: ThemeSpec) {
        if let data = try? JSONEncoder().encode(spec) { defaults.set(data, forKey: key) }
    }
    static func loadSelected() -> ThemeSpec {
        if let data = defaults.data(forKey: key), let spec = try? JSONDecoder().decode(ThemeSpec.self, from: data) {
            return spec
        }
        return ThemePresets.all[0]
    }
}

enum ThemePresets {
    static let all: [ThemeSpec] = [
        ThemeSpec(name: "Midnight", colors: ["0F2027", "203A43", "2C5364"], accent: "5FD0E0", style: .gradient),
        ThemeSpec(name: "Neon", colors: ["3A0CA3", "7209B7", "F72585"], accent: "4CC9F0", style: .aurora),
        ThemeSpec(name: "Sunset", colors: ["FF512F", "DD2476", "7B2FF7"], accent: "FFD166", style: .gradient),
        ThemeSpec(name: "Pastel", colors: ["A1C4FD", "C2E9FB", "FBC2EB"], accent: "8E7CFF", style: .aurora, lightText: false),
        ThemeSpec(name: "Terminal", colors: ["0B0F0B", "0B0F0B"], accent: "39FF14", style: .solid),
        ThemeSpec(name: "Ocean", colors: ["2193B0", "6DD5ED"], accent: "FFFFFF", style: .gradient),
        ThemeSpec(name: "Mono", colors: ["1C1C1E", "3A3A3C"], accent: "FFFFFF", style: .bands),
        ThemeSpec(name: "Candy", colors: ["FF9A9E", "FAD0C4", "FAD0C4", "A18CD1"], accent: "FF4D8D", style: .bands, lightText: false),
        ThemeSpec(name: "Forest", colors: ["134E5E", "71B280"], accent: "EFFFB0", style: .gradient),
        ThemeSpec(name: "Grape", colors: ["41295A", "2F0743"], accent: "B06AB3", style: .aurora),
        ThemeSpec(name: "Crimson Rose", colors: ["090304", "8C0E1C", "C21E56"], accent: "FF4D6D", style: .aurora),
        ThemeSpec(name: "Crimson Royale", colors: ["0A0306", "8C0E1C", "4A1E70"], accent: "B06AF0", style: .gradient),
    ]
}
