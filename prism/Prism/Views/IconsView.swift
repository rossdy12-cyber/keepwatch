import SwiftUI

struct IconSpec: Identifiable, Hashable {
    let label: String
    let symbol: String
    var id: String { label }
}

enum IconCatalog {
    static let apps: [IconSpec] = [
        .init(label: "Phone", symbol: "phone.fill"),
        .init(label: "Messages", symbol: "message.fill"),
        .init(label: "Mail", symbol: "envelope.fill"),
        .init(label: "Safari", symbol: "safari.fill"),
        .init(label: "Camera", symbol: "camera.fill"),
        .init(label: "Photos", symbol: "photo.on.rectangle.angled"),
        .init(label: "Music", symbol: "music.note"),
        .init(label: "Maps", symbol: "map.fill"),
        .init(label: "Calendar", symbol: "calendar"),
        .init(label: "Clock", symbol: "clock.fill"),
        .init(label: "Notes", symbol: "note.text"),
        .init(label: "Settings", symbol: "gearshape.fill"),
        .init(label: "Weather", symbol: "cloud.sun.fill"),
        .init(label: "Calculator", symbol: "plusminus"),
        .init(label: "Files", symbol: "folder.fill"),
        .init(label: "App Store", symbol: "bag.fill"),
        .init(label: "Wallet", symbol: "creditcard.fill"),
        .init(label: "Home", symbol: "house.fill"),
        .init(label: "Reminders", symbol: "checklist"),
        .init(label: "Fitness", symbol: "flame.fill"),
    ]
}

struct IconsView: View {
    @EnvironmentObject var store: ThemeStore
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var toast: String?
    @State private var showGuide = false

    private let cols = [GridItem(.adaptive(minimum: 90), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Tap the apps you want a matching icon for, then **Generate**. Prism renders each tile in the active theme and saves it to Photos — you apply them with the Shortcuts trick (tap **How it works**).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(IconCatalog.apps) { app in
                            IconPick(app: app, theme: store.selected, on: selected.contains(app.id))
                                .onTapGesture {
                                    if selected.contains(app.id) { selected.remove(app.id) } else { selected.insert(app.id) }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Icon Pack")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(selected.isEmpty ? "Select all" : "Clear") {
                        selected = selected.isEmpty ? Set(IconCatalog.apps.map(\.id)) : []
                    }
                    Spacer()
                    Button {
                        Task { await generate() }
                    } label: {
                        Label(busy ? "Rendering…" : "Generate (\(selected.count))", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || busy)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showGuide = true } label: { Label("How it works", systemImage: "questionmark.circle") }
                }
            }
            .sheet(isPresented: $showGuide) { IconGuide() }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    @MainActor
    private func generate() async {
        busy = true; defer { busy = false }
        let picks = IconCatalog.apps.filter { selected.contains($0.id) }
        var saved = 0
        for app in picks {
            if let img = Renderers.iconTile(store.selected, symbol: app.symbol),
               await Renderers.save(img) { saved += 1 }
        }
        flash(saved > 0 ? "\(saved) icon\(saved == 1 ? "" : "s") saved to Photos" : "Couldn't save — allow Photos access")
        if saved > 0 { showGuide = true }
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { toast = nil } }
    }
}

struct IconPick: View {
    let app: IconSpec
    let theme: ThemeSpec
    let on: Bool

    var body: some View {
        VStack(spacing: 6) {
            IconArt(spec: theme, symbol: app.symbol)
                .frame(width: 72, height: 72)
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, theme.accentColor)
                            .padding(3)
                    }
                }
                .scaleEffect(on ? 0.96 : 1)
                .animation(.spring(duration: 0.2), value: on)
            Text(app.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct IconGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Prism can't replace real app icons directly — Apple doesn't allow that without a jailbreak. Instead you use Apple's own **Shortcuts** app to make home-screen tiles that open your apps with these custom images.", systemImage: "info.circle")
                        .font(.footnote)
                }
                Section("Apply an icon") {
                    step(1, "Open the **Shortcuts** app ▸ **+** ▸ add action **Open App**, and choose the app (e.g. Messages).")
                    step(2, "Tap the share icon ▸ **Add to Home Screen**.")
                    step(3, "Tap the icon thumbnail ▸ **Choose Photo**, pick the tile Prism saved, and name it.")
                    step(4, "**Add** — the themed tile lands on your home screen. Move the original app to the App Library or a back page.")
                }
                Section {
                    Text("Tip: put all your real apps on a second page and keep only the Prism tiles (plus a matching Prism widget) on the first for a fully themed look.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("How it works")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline.monospacedDigit())
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text).font(.subheadline)
        }
    }
}
