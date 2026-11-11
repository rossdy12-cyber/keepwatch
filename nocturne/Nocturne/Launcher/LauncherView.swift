import SwiftUI

struct LauncherView: View {
    @EnvironmentObject var store: Store
    @Binding var route: Module?

    private let tiles: [Module] = [.phone, .messages, .clock, .weather, .notes, .calculator, .music, .settings]
    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    var body: some View {
        ZStack {
            GothicBackground(theme: store.theme)
            VStack(spacing: 18) {
                header
                Filigree(theme: store.theme).padding(.horizontal, 40)
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(tiles) { m in
                            AppTile(module: m, theme: store.theme)
                                .onTapGesture { route = m }
                        }
                    }
                    .padding(20)
                }
            }
            .padding(.top, 20)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(Date(), format: .dateTime.hour().minute())
                .font(.system(size: 54, weight: .bold, design: .serif))
                .foregroundStyle(store.theme.textColor)
            Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 15, weight: .regular, design: .serif))
                .foregroundStyle(store.theme.mutedColor)
            Text("N O C T U R N E")
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .tracking(4)
                .foregroundStyle(store.theme.accentColor)
                .padding(.top, 6)
        }
    }
}

struct AppTile: View {
    let module: Module
    let theme: GothicTheme

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(colors: [theme.panelColor, theme.bgColors.last ?? .black],
                                       startPoint: .top, endPoint: .bottom)
                    )
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [theme.accentColor.opacity(0.7), theme.accent2Color.opacity(0.2)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                Image(systemName: module.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                    .shadow(color: theme.accentColor.opacity(0.5), radius: 10)
            }
            .frame(height: 96)
            Text(module.title)
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(theme.textColor)
        }
    }
}
