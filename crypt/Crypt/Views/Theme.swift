import SwiftUI
import UIKit

enum Theme {
    static let void = Color(red: 0.035, green: 0.020, blue: 0.027)        // #090507
    static let surface = Color(red: 0.082, green: 0.039, blue: 0.051)     // #150A0D
    static let raised = Color(red: 0.125, green: 0.055, blue: 0.071)      // #200E12
    static let line = Color(red: 0.26, green: 0.09, blue: 0.12)           // #43171F
    static let crimson = Color(red: 0.545, green: 0.039, blue: 0.102)     // #8B0A1A
    static let blood = Color(red: 0.769, green: 0.118, blue: 0.227)       // #C41E3A
    static let ember = Color(red: 0.90, green: 0.32, blue: 0.38)          // #E65261
    static let bone = Color(red: 0.918, green: 0.875, blue: 0.816)        // #EADFD0
    static let ash = Color(red: 0.62, green: 0.55, blue: 0.53)            // #9E8C87

    static let uiVoid = UIColor(red: 0.035, green: 0.020, blue: 0.027, alpha: 1)
    static let uiBone = UIColor(red: 0.918, green: 0.875, blue: 0.816, alpha: 1)
    static let uiBlood = UIColor(red: 0.769, green: 0.118, blue: 0.227, alpha: 1)

    /// Blackletter, for titles.
    static func gothic(_ size: CGFloat) -> Font { .custom("UnifrakturMaguntia", size: size) }
    /// Engraved capitals, for labels and buttons.
    static func engraved(_ size: CGFloat) -> Font { .custom("Cinzel-Regular", size: size) }
    /// Book serif, for reading.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .semibold, .bold, .heavy, .black: return .custom("Baskerville-SemiBold", size: size)
        default: return .custom("Baskerville", size: size)
        }
    }
    static func serifItalic(_ size: CGFloat) -> Font { .custom("Baskerville-Italic", size: size) }

    static func configureAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiVoid
        nav.shadowColor = UIColor(red: 0.26, green: 0.09, blue: 0.12, alpha: 1)
        nav.titleTextAttributes = [
            .foregroundColor: uiBone,
            .font: UIFont(name: "UnifrakturMaguntia", size: 24) ?? UIFont.systemFont(ofSize: 20)
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: uiBone,
            .font: UIFont(name: "UnifrakturMaguntia", size: 40) ?? UIFont.systemFont(ofSize: 34)
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = uiBlood

        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = uiVoid
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar

        UITextView.appearance().backgroundColor = .clear
        UISearchBar.appearance().tintColor = uiBlood
    }
}

/// Black with a faint crimson glow, like candlelight through stained glass.
struct GothicBackground: View {
    var body: some View {
        ZStack {
            Theme.void
            RadialGradient(
                colors: [Theme.crimson.opacity(0.35), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [Theme.crimson.opacity(0.18), .clear],
                center: .bottom,
                startRadius: 10,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

/// ── ✠ ──
struct OrnamentDivider: View {
    var symbol = "✠"

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.blood)
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, Theme.crimson, .clear], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
    }
}

/// A wax-seal monogram for a sender.
struct Sigil: View {
    let name: String
    var size: CGFloat = 42

    private var initial: String {
        let letters = name.trimmingCharacters(in: .whitespaces).filter { $0.isLetter }
        return letters.first.map { String($0).uppercased() } ?? "✠"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.blood, Theme.crimson, Color(red: 0.25, green: 0.0, blue: 0.04)],
                                     center: .topLeading, startRadius: 2, endRadius: size))
            Circle()
                .strokeBorder(Theme.bone.opacity(0.25), lineWidth: 1)
                .padding(3)
            Text(initial)
                .font(Theme.gothic(size * 0.55))
                .foregroundStyle(Theme.bone)
                .offset(y: size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.crimson.opacity(0.6), radius: 6)
        .accessibilityHidden(true)
    }
}

struct CrimsonButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.engraved(16))
            .tracking(1.5)
            .foregroundStyle(Theme.bone)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background {
                if filled {
                    LinearGradient(colors: [Theme.blood, Theme.crimson], startPoint: .top, endPoint: .bottom)
                } else {
                    Theme.surface
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.blood.opacity(filled ? 0.9 : 0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: Theme.crimson.opacity(configuration.isPressed ? 0.2 : 0.55), radius: 10)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A labelled field with an underline, styled like an inscription.
struct InscribedField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Theme.engraved(11))
                .tracking(2)
                .foregroundStyle(Theme.ash)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.ash.opacity(0.5)))
                } else {
                    TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.ash.opacity(0.5)))
                        .keyboardType(keyboard)
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Theme.serif(18))
            .foregroundStyle(Theme.bone)
            .tint(Theme.blood)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
        }
    }
}

extension View {
    func gothicTitle(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(Theme.gothic(26))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

extension Date {
    var mailStamp: String {
        let calendar = Calendar.current
        if self == .distantPast { return "" }
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
