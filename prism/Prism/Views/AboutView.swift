import SwiftUI

struct AboutView: View {
    @EnvironmentObject var store: ThemeStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        IconArt(spec: store.selected, symbol: "paintpalette.fill")
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading) {
                            Text("Prism").font(.title2.bold())
                            Text("Theme studio").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section("What Prism does") {
                    row("photo.fill", "Wallpapers", "Renders your theme as a full-resolution wallpaper and saves it to Photos.")
                    row("app.badge.fill", "Icon packs", "Makes matching home-screen tiles you apply through the Shortcuts app.")
                    row("rectangle.3.group.fill", "Widgets", "A Prism widget on your home screen picks up the active theme automatically.")
                }

                Section("Being honest about iOS") {
                    Text("Without a jailbreak, apps can't restyle the Phone app, Messages bubbles, or the system UI, and they can't swap real app icons silently. Prism works entirely within what Apple allows: wallpapers via Photos, icons via Shortcuts, and a themed widget. Change the active theme on the Themes tab and everything here — plus the widget — follows it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Make the look cohesive") {
                    Text("1. Pick or design a theme.\n2. Save its wallpaper.\n3. Generate an icon pack and apply a few via Shortcuts.\n4. Add the Prism widget (long-press home screen ▸ **+** ▸ Prism).\n5. Tuck the real apps into the App Library.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
        }
    }

    private func row(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
