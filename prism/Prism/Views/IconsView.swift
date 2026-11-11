import SwiftUI
import UIKit

struct IconSpec: Identifiable, Hashable {
    let label: String
    let symbol: String
    /// What tapping the installed icon opens. Stock apps that publish a launch URL open directly; the rest
    /// open their closest target.
    let url: String
    var id: String { label }
}

enum IconCatalog {
    static let apps: [IconSpec] = [
        .init(label: "Phone", symbol: "phone.fill", url: "tel://"),
        .init(label: "Messages", symbol: "message.fill", url: "sms://"),
        .init(label: "Mail", symbol: "envelope.fill", url: "mailto://"),
        .init(label: "Safari", symbol: "safari.fill", url: "https://www.google.com"),
        .init(label: "Camera", symbol: "camera.fill", url: "camera://"),
        .init(label: "Photos", symbol: "photo.on.rectangle.angled", url: "photos-redirect://"),
        .init(label: "Music", symbol: "music.note", url: "music://"),
        .init(label: "Maps", symbol: "map.fill", url: "maps://"),
        .init(label: "Calendar", symbol: "calendar", url: "calshow://"),
        .init(label: "Clock", symbol: "clock.fill", url: "clock-app://"),
        .init(label: "Notes", symbol: "note.text", url: "mobilenotes://"),
        .init(label: "Settings", symbol: "gearshape.fill", url: "App-Prefs://"),
        .init(label: "Weather", symbol: "cloud.sun.fill", url: "weather://"),
        .init(label: "Calculator", symbol: "plusminus", url: "calc://"),
        .init(label: "Files", symbol: "folder.fill", url: "shareddocuments://"),
        .init(label: "App Store", symbol: "bag.fill", url: "itms-apps://"),
        .init(label: "Wallet", symbol: "creditcard.fill", url: "shoebox://"),
        .init(label: "Home", symbol: "house.fill", url: "com.apple.home://"),
        .init(label: "Reminders", symbol: "checklist", url: "x-apple-reminderkit://"),
        .init(label: "Fitness", symbol: "flame.fill", url: "fitness://"),
    ]
}

struct IconsView: View {
    @EnvironmentObject var store: ThemeStore
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var toast: String?
    @State private var showGuide = false
    @State private var showProfileHelp = false

    private let cols = [GridItem(.adaptive(minimum: 90), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Pick the apps you want themed icons for, then **Install as profile** — Prism builds a configuration profile and iOS adds the icons to your home screen in a couple of taps. (Prefer the manual way? **Save to Photos** and use the Shortcuts trick — tap **How it works**.)")
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
                VStack(spacing: 10) {
                    Button {
                        Task { await installProfile() }
                    } label: {
                        Label(busy ? "Preparing…" : "Install as profile (\(selected.count))", systemImage: "square.and.arrow.down.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selected.isEmpty || busy)
                    HStack {
                        Button(selected.isEmpty ? "Select all" : "Clear") {
                            selected = selected.isEmpty ? Set(IconCatalog.apps.map(\.id)) : []
                        }
                        Spacer()
                        Button { Task { await generate() } } label: { Label("Save to Photos", systemImage: "photo") }
                            .disabled(selected.isEmpty || busy)
                    }
                    .font(.subheadline)
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
            .sheet(isPresented: $showProfileHelp) { ProfileHelp(theme: store.selected) }
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

    /// Builds a configuration profile of themed web-clip icons and opens Safari so iOS offers to install it.
    @MainActor
    private func installProfile() async {
        busy = true; defer { busy = false }
        let picks = IconCatalog.apps.filter { selected.contains($0.id) }
        var clips: [WebClip] = []
        for app in picks {
            if let img = Renderers.iconTile(store.selected, symbol: app.symbol, px: 180),
               let png = img.pngData() {
                clips.append(WebClip(label: app.label, url: app.url, iconPNG: png))
            }
        }
        guard !clips.isEmpty, let config = ProfileBuilder.mobileconfig(clips, themeName: store.selected.name) else {
            flash("Couldn't build the profile — try again."); return
        }
        ProfileServer.shared.start(serving: config) { url in
            Task { @MainActor in
                guard let url else { flash("Couldn't start the installer."); return }
                await UIApplication.shared.open(url)
                showProfileHelp = true
            }
        }
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

/// Shown right after Safari opens the profile, so the person knows to finish the install in Settings.
struct ProfileHelp: View {
    @Environment(\.dismiss) private var dismiss
    let theme: ThemeSpec

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Safari just downloaded a profile with your themed icons. iOS only adds it once you confirm — a couple of taps:", systemImage: "square.and.arrow.down.on.square")
                        .font(.footnote)
                }
                Section("Finish installing") {
                    row(1, "If Safari asks, tap “Allow” to let the profile download.")
                    row(2, "Open Settings — you'll see “Profile Downloaded” near the top.")
                    row(3, "Tap it, then “Install” (top right), enter your passcode, and “Install” again.")
                    row(4, "Your themed icons appear on the home screen. Tuck the original apps into the App Library.")
                }
                Section {
                    Text("Remove the icons any time from **Settings ▸ General ▸ VPN & Device Management ▸ Prism**. A few stock apps don't publish a launch address, so those icons open their closest match — the themed look still installs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Install profile")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline.monospacedDigit())
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.accentColor.opacity(0.25)))
            Text(text).font(.subheadline)
        }
    }
}
