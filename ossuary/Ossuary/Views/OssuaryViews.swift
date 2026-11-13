import SwiftUI

@main
struct OssuaryApp: App {
    @StateObject private var store = OssuaryStore()

    init() {
        Theme.configureAppearance()
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = Theme.uiVoid
        let item = UITabBarItemAppearance()
        let font = UIFont(name: "Cinzel-Regular", size: 10) ?? .systemFont(ofSize: 10)
        let ash = UIColor(red: 0.62, green: 0.55, blue: 0.53, alpha: 1)
        item.normal.titleTextAttributes = [.font: font, .foregroundColor: ash]
        item.normal.iconColor = ash
        item.selected.titleTextAttributes = [.font: font, .foregroundColor: Theme.uiBlood]
        item.selected.iconColor = Theme.uiBlood
        tab.stackedLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isConfigured {
                    TabView {
                        CryptsView().tabItem { Label("Crypts", systemImage: "building.columns") }
                        RecentView().tabItem { Label("Risen", systemImage: "sparkles") }
                        CarriedView().tabItem { Label("Carried", systemImage: "arrow.down.circle") }
                    }
                    .overlay(alignment: .bottom) {
                        if let message = store.errorMessage {
                            Text(message)
                                .font(Theme.serif(14))
                                .foregroundStyle(Theme.bone)
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
                                .padding(.horizontal)
                                .padding(.bottom, 60)
                                .onTapGesture { store.errorMessage = nil }
                        }
                    }
                } else {
                    SetupView()
                }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.blood)
        }
    }
}

struct ArtImage: View {
    let url: URL?
    let title: String
    @State private var image: UIImage?
    @State private var tried = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                // A blank tombstone with the title, for games with no art.
                ZStack {
                    LinearGradient(colors: [Theme.raised, Theme.void], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 8) {
                        Text("✠").foregroundStyle(Theme.crimson)
                        Text(title)
                            .font(Theme.serif(13, weight: .semibold))
                            .foregroundStyle(Theme.bone.opacity(tried ? 0.85 : 0.3))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(.horizontal, 8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            }
        }
        .task(id: url) {
            if let url { image = await ArtCache.shared.image(url) }
            tried = true
        }
    }
}

struct GameTile: View {
    @EnvironmentObject private var store: OssuaryStore
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(ArtImage(url: store.artURL(game), title: game.title))
                .overlay(alignment: .topTrailing) {
                    if store.isDownloaded(game) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.bone, Theme.crimson)
                            .padding(4)
                    }
                }
            Text(game.title)
                .font(Theme.serif(13, weight: .semibold))
                .foregroundStyle(Theme.bone)
                .lineLimit(2)
        }
    }
}

// MARK: Systems

struct CryptsView: View {
    @EnvironmentObject private var store: OssuaryStore
    @State private var query = ""
    @State private var results: [Game] = []
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let gameColumns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                ScrollView {
                    if !query.isEmpty {
                        LazyVGrid(columns: gameColumns, spacing: 16) {
                            ForEach(results) { game in
                                NavigationLink(value: game) { GameTile(game: game) }.buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    } else if store.systems.isEmpty {
                        VStack(spacing: 12) {
                            Text("✠").font(.system(size: 34)).foregroundStyle(Theme.crimson)
                            Text("Empty crypts").font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                            Text("Put one folder per system (snes, gba, psx, PC…) in your games folder on the NAS.")
                                .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                        }
                        .padding(30)
                        .padding(.top, 80)
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(store.systems) { system in
                                NavigationLink(value: system) { SystemCard(system: system) }.buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
                .refreshable { await store.loadSystems() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Crypts")
            .searchable(text: $query, prompt: Text("Search every system"))
            .task(id: query) {
                guard !query.isEmpty else { results = []; return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                results = await store.search(query)
            }
            .task { if store.systems.isEmpty { await store.loadSystems() } }
            .navigationDestination(for: GameSystem.self) { SystemView(system: $0) }
            .navigationDestination(for: Game.self) { GameView(game: $0) }
        }
    }
}

struct SystemCard: View {
    @EnvironmentObject private var store: OssuaryStore
    let system: GameSystem

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.clear
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay(
                        ArtImage(url: system.cover.flatMap { store.artURL(path: $0) }, title: system.name)
                            .blur(radius: 1.5)
                            .overlay(Theme.void.opacity(0.35))
                    )
                    .clipShape(ArchWindow())
                ArchWindow().stroke(LinearGradient(colors: [Theme.blood, Theme.crimson], startPoint: .top, endPoint: .bottom), lineWidth: 2)
                Text(String(system.name.prefix(1)))
                    .font(Theme.gothic(54))
                    .foregroundStyle(Theme.bone)
                    .shadow(color: .black, radius: 6)
            }
            .shadow(color: Theme.crimson.opacity(0.45), radius: 10)
            Text(system.name)
                .font(Theme.serif(15, weight: .semibold))
                .foregroundStyle(Theme.bone)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(system.count) \(system.count == 1 ? "game" : "games")" + (system.retrodeck ? " · RetroDeck" : ""))
                .font(Theme.engraved(10))
                .foregroundStyle(Theme.ash)
        }
    }
}

struct SystemView: View {
    @EnvironmentObject private var store: OssuaryStore
    let system: GameSystem
    @State private var games: [Game]?
    @State private var error: String?
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                if let games {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(games) { game in
                            NavigationLink(value: game) { GameTile(game: game) }.buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                } else if let error {
                    Text(error).font(Theme.serif(15)).foregroundStyle(Theme.ember).padding(30)
                } else {
                    ProgressView().tint(Theme.blood).padding(.top, 120)
                }
            }
            .refreshable { await load() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .gothicTitle(system.name)
        .task { if games == nil { await load() } }
    }

    private func load() async {
        do { games = try await store.games(in: system.id) } catch { self.error = error.localizedDescription }
    }
}

// MARK: Game

struct GameView: View {
    @EnvironmentObject private var store: OssuaryStore
    let game: Game

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(spacing: 18) {
                    ArtImage(url: store.artURL(game), title: game.title)
                        .frame(maxHeight: 320)
                        .shadow(color: Theme.crimson.opacity(0.6), radius: 18)
                        .padding(.top, 12)
                    Text(game.title)
                        .font(Theme.gothic(34))
                        .foregroundStyle(Theme.bone)
                        .multilineTextAlignment(.center)
                    OrnamentDivider().padding(.horizontal, 30)
                    VStack(alignment: .leading, spacing: 10) {
                        row("System", store.systems.first { $0.id == game.system }?.name ?? game.system)
                        row("File", game.file)
                        row("Size", game.sizeText)
                        row("Added", Date(timeIntervalSince1970: game.added).formatted(date: .abbreviated, time: .omitted))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var actions: some View {
        if game.folder {
            Text("This game is a folder. Zip it on the NAS to download it here.")
                .font(Theme.serifItalic(14)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
        } else if let fraction = store.progress[game.path] {
            VStack(spacing: 8) {
                ProgressView(value: fraction).tint(Theme.blood)
                HStack {
                    Text("Exhuming… \(Int(fraction * 100))%").font(Theme.engraved(12)).foregroundStyle(Theme.ash)
                    Spacer()
                    Button("Cancel") { store.cancel(game) }.font(Theme.engraved(12))
                }
            }
        } else if store.isDownloaded(game) {
            VStack(spacing: 10) {
                Label("On this iPhone", systemImage: "checkmark.seal.fill")
                    .font(Theme.engraved(14)).foregroundStyle(Theme.ember)
                ShareLink(item: store.localURL(for: game)) {
                    Label("Share or open in another app", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(CrimsonButtonStyle(filled: false))
                if game.retrodeck {
                    retrodeckHelp
                }
            }
        } else {
            VStack(spacing: 10) {
                Button {
                    store.download(game)
                } label: {
                    Label("Carry it to this iPhone (\(game.sizeText))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(CrimsonButtonStyle())
                if game.retrodeck {
                    Text("Playable in RetroDeck once downloaded.")
                        .font(Theme.serifItalic(13)).foregroundStyle(Theme.ash)
                }
            }
        }
    }

    private var retrodeckHelp: some View {
        Text("To play: open RetroDeck → Import ROMs → Browse → On My iPhone → Ossuary → \(game.system) → \(game.file).")
            .font(Theme.serifItalic(13))
            .foregroundStyle(Theme.ash)
            .multilineTextAlignment(.center)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label.uppercased()).font(Theme.engraved(11)).tracking(1.5).foregroundStyle(Theme.ash).frame(width: 80, alignment: .leading)
            Text(value).font(Theme.serif(16)).foregroundStyle(Theme.bone).textSelection(.enabled)
        }
    }
}

// MARK: Recent

struct RecentView: View {
    @EnvironmentObject private var store: OssuaryStore
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                ScrollView {
                    if store.recent.isEmpty {
                        Text("Nothing has risen lately.")
                            .font(Theme.serifItalic(16)).foregroundStyle(Theme.ash).padding(.top, 120)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.recent) { game in
                            NavigationLink(value: game) { GameTile(game: game) }.buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                }
                .refreshable { await store.loadRecent() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Lately Risen")
            .task { await store.loadRecent() }
            .navigationDestination(for: Game.self) { GameView(game: $0) }
        }
    }
}

// MARK: Downloads

struct CarriedView: View {
    @EnvironmentObject private var store: OssuaryStore
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    Section {
                        if store.local.isEmpty {
                            Text("No games carried yet. Open a game and tap Carry it to this iPhone.")
                                .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                        }
                        ForEach(store.local) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(Theme.serif(15, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(2)
                                    Text("\(item.system) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                                        .font(Theme.engraved(10)).foregroundStyle(Theme.ash)
                                }
                                Spacer()
                                ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.delete(item) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    } header: {
                        Text("ON THIS IPHONE").font(Theme.engraved(12)).tracking(2).foregroundStyle(Theme.ash)
                    } footer: {
                        Text("These are in the Files app under On My iPhone › Ossuary. In RetroDeck, use Import ROMs and pick them from there.")
                            .font(Theme.serifItalic(12)).foregroundStyle(Theme.ash)
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        Text(store.address).font(Theme.serif(14)).foregroundStyle(Theme.ash)
                        Button("Disconnect from server", role: .destructive) { confirmForget = true }
                            .font(Theme.engraved(13))
                    } header: {
                        Text("SERVER").font(Theme.engraved(12)).tracking(2).foregroundStyle(Theme.ash)
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Carried")
            .onAppear { store.scanLocal() }
            .confirmationDialog("Disconnect from the server? Downloaded games stay on this iPhone.", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { store.forget() }
            }
        }
    }
}

// MARK: Setup

struct SetupView: View {
    @EnvironmentObject private var store: OssuaryStore
    @State private var address = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("✠").font(.system(size: 26)).foregroundStyle(Theme.blood).shadow(color: Theme.blood, radius: 12)
                        Text("Ossuary")
                            .font(Theme.gothic(66))
                            .foregroundStyle(LinearGradient(colors: [Theme.bone, Theme.ember], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.crimson, radius: 18)
                        Text("WHERE OLD GAMES REST").font(Theme.engraved(12)).tracking(4).foregroundStyle(Theme.ash)
                        OrnamentDivider().padding(.top, 10)
                    }
                    .padding(.top, 30)
                    InscribedField(label: "Server", text: $address, prompt: "http://100.x.y.z:8789", keyboard: .URL)
                    InscribedField(label: "Token", text: $token, prompt: "OSSUARY_TOKEN from the server's YAML", secure: true)
                    if let error {
                        Text(error).font(Theme.serif(15)).foregroundStyle(Theme.ember).multilineTextAlignment(.center)
                    }
                    Button {
                        Task {
                            working = true
                            defer { working = false }
                            do { try await store.connect(address: address, token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack { if working { ProgressView().tint(Theme.bone) }; Text(working ? "Unsealing…" : "Open the Ossuary") }
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    .disabled(working || address.isEmpty || token.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

struct ArchWindow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, r = w * 0.85, offset = r - w / 2
        let rise = sqrt(max(0, r * r - offset * offset))
        let spring = rect.minY + rise
        let apex = atan2(rise, offset)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: spring))
        for i in 1...24 {
            let t = CGFloat.pi - apex * CGFloat(i) / 24
            path.addLine(to: CGPoint(x: rect.minX + r + r * cos(t), y: spring - r * sin(t)))
        }
        for i in 1...24 {
            let t = apex - apex * CGFloat(i) / 24
            path.addLine(to: CGPoint(x: rect.maxX - r + r * cos(t), y: spring - r * sin(t)))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
