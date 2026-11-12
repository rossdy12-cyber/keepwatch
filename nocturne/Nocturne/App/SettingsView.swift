import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    private var theme: GothicTheme { store.theme }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                GothicTitle(text: "Altar", theme: theme, size: 26).padding(.top, 50)

                section("Raiment") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(GothicThemes.all) { t in
                            Button { store.selectTheme(t) } label: { themeSwatch(t) }
                        }
                    }
                }

                section("Requiem — Navidrome") {
                    field("Server URL", text: $store.navURL, placeholder: "music.nas-server.co.uk")
                    field("Username", text: $store.navUser)
                    secureField("Password", text: $store.navPass)
                    note("Used only to sign Subsonic requests to your own server. Stored on this device.")
                }

                section("Messages — Chat Relay") {
                    field("Relay URL", text: $store.relayURL, placeholder: "jarvis.nas-server.co.uk")
                    field("Token (optional)", text: $store.relayToken)
                    field("Your name", text: $store.displayName)
                    field("Their name", text: $store.partnerName, placeholder: "Lauren")
                    HStack(alignment: .bottom, spacing: 8) {
                        field("Private room id", text: $store.chatRoom)
                        Button {
                            store.chatRoom = "room-" + UUID().uuidString.prefix(8).lowercased()
                        } label: {
                            Image(systemName: "dice").padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor.opacity(0.2)))
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                    note("Easiest: open your invitation link from the Nocturne server and tap \"Open Nocturne and sign in\" — it fills all of this in. With a personal sign-in, your name and conversations come from the server.")
                }

                section("About") {
                    Text("Nocturne can't restyle Apple's own Phone, Messages or system screens — iOS forbids that without a jailbreak. Instead it gives you fully gothic *replacements*: the dialer hands calls to the system, SMS uses Apple's send sheet, and chat runs on your homelab. Pin any tool as its own icon with Prism's Shortcuts trick (nocturne://messages, nocturne://music, …).")
                        .font(.system(.footnote, design: .serif)).foregroundStyle(theme.mutedColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }

    private func themeSwatch(_ t: GothicTheme) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: t.bgColors, startPoint: .top, endPoint: .bottom))
                Circle().fill(t.accentColor).frame(width: 22, height: 22)
            }
            .frame(height: 60)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(store.theme.name == t.name ? t.accentColor : .white.opacity(0.1),
                                  lineWidth: store.theme.name == t.name ? 2.5 : 1)
            )
            Text(t.name).font(.caption2).foregroundStyle(theme.textColor).lineLimit(1)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold, design: .serif))
                .tracking(2).foregroundStyle(theme.accentColor)
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.panelColor.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.accentColor.opacity(0.2)))
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(theme.mutedColor)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(theme.bgColors.first ?? .black)
                .clipShape(RoundedRectangle(cornerRadius: 8)).foregroundStyle(theme.textColor)
        }
    }
    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(theme.mutedColor)
            SecureField("", text: text)
                .padding(10).background(theme.bgColors.first ?? .black)
                .clipShape(RoundedRectangle(cornerRadius: 8)).foregroundStyle(theme.textColor)
        }
    }
    private func note(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(theme.mutedColor.opacity(0.8))
    }
}
