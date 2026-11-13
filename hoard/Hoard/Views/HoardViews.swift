import SwiftUI

@main
struct HoardApp: App {
    @StateObject private var store = HoardStore()

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
                        LibraryView().tabItem { Label("Hoard", systemImage: "square.stack.3d.up") }
                        CovenView().tabItem { Label("Coven", systemImage: "person.3") }
                        CovetView().tabItem { Label("Covet", systemImage: "heart.text.square") }
                        ProfileView().tabItem { Label("Sanctum", systemImage: "person.crop.circle") }
                    }
                    .task { await store.refreshAll() }
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

struct SteamImage: View {
    let url: URL?
    var fallback: URL? = nil
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            }
        }
        .task(id: url) {
            var loaded: UIImage?
            if let url { loaded = await ImageCache.shared.image(url) }
            if loaded == nil, let fallback { loaded = await ImageCache.shared.image(fallback) }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

// MARK: Library

struct LibraryView: View {
    @EnvironmentObject private var store: HoardStore
    @AppStorage("hoard.sort") private var sort: LibrarySort = .recent
    @State private var query = ""
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                let games = store.sorted(sort, query: query)
                if games.isEmpty {
                    VStack(spacing: 12) {
                        if store.loadingLibrary { ProgressView().tint(Theme.blood).scaleEffect(1.4) }
                        Text(store.loadingLibrary ? "Opening the vault" : (sort == .unplayed ? "No shame here" : "An empty hoard"))
                            .font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                        Text(store.errorMessage ?? (store.loadingLibrary ? "Counting your games…" : "Nothing matches."))
                            .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else {
                    ScrollView {
                        Text("\(games.count) games · \(Steam.hours(store.totalMinutes)) played")
                            .font(Theme.engraved(11)).tracking(1.5).foregroundStyle(Theme.ash)
                            .padding(.top, 6)
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(games) { game in
                                NavigationLink(value: game) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        SteamImage(url: game.capsule, fallback: game.header)
                                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                                            .shadow(color: Theme.crimson.opacity(game.recentMinutes > 0 ? 0.6 : 0), radius: 8)
                                        Text(game.title)
                                            .font(Theme.serif(13, weight: .semibold))
                                            .foregroundStyle(Theme.bone)
                                            .lineLimit(1)
                                        Text(game.hoursText)
                                            .font(Theme.engraved(10))
                                            .foregroundStyle(game.minutes == 0 ? Theme.ember : Theme.ash)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                    .refreshable { await store.refreshLibrary() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle(sort == .unplayed ? "Pile of Shame" : "Hoard")
            .searchable(text: $query, prompt: Text("Search your hoard"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                    .accessibilityLabel("Sort")
                }
            }
            .navigationDestination(for: OwnedGame.self) { GameView(game: $0) }
        }
    }
}

// MARK: Game

struct GameView: View {
    @EnvironmentObject private var store: HoardStore
    @Environment(\.openURL) private var openURL
    let game: OwnedGame
    @State private var achievements: [Achievement]?
    @State private var price: StorePrice??
    @State private var achievementError: String?
    @State private var showLocked = true

    private var unlocked: Int { achievements?.filter(\.achieved).count ?? 0 }

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SteamImage(url: game.hero, fallback: game.header)
                        .aspectRatio(1920.0 / 620.0, contentMode: .fit)
                        .overlay(LinearGradient(colors: [.clear, Theme.void], startPoint: .center, endPoint: .bottom))
                    VStack(alignment: .leading, spacing: 14) {
                        Text(game.title)
                            .font(Theme.serif(26, weight: .semibold))
                            .foregroundStyle(Theme.bone)
                        HStack(spacing: 18) {
                            stat("PLAYED", game.hoursText)
                            if game.recentMinutes > 0 { stat("LAST 2 WEEKS", Steam.hours(game.recentMinutes)) }
                            if let last = game.lastPlayed { stat("LAST", last.formatted(date: .abbreviated, time: .omitted)) }
                        }
                        if let price, let value = price {
                            HStack {
                                Text("Store price")
                                    .font(Theme.serif(15)).foregroundStyle(Theme.ash)
                                Spacer()
                                if value.discount_percent > 0 {
                                    Text("−\(value.discount_percent)%").font(Theme.engraved(11)).foregroundStyle(Theme.bone)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Theme.crimson, in: RoundedRectangle(cornerRadius: 3))
                                }
                                Text(value.final_formatted).font(Theme.serif(16, weight: .semibold)).foregroundStyle(Theme.ember)
                            }
                        }
                        Button {
                            openURL(Steam.storePage(game.appid))
                        } label: {
                            Label("Open in Steam", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(CrimsonButtonStyle(filled: false))
                        OrnamentDivider()
                        achievementSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let list = try? Steam.achievements(game.appid, steamID: store.steamID, key: store.apiKey)
            async let prices = Steam.prices([game.appid])
            achievements = await list ?? []
            price = (await prices)[game.appid]
        }
    }

    @ViewBuilder
    private var achievementSection: some View {
        if let achievements {
            if achievements.isEmpty {
                Text("This game has no achievements.")
                    .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
            } else {
                HStack {
                    Text("Trophies").font(Theme.gothic(28)).foregroundStyle(Theme.bone)
                    Spacer()
                    Text("\(unlocked) / \(achievements.count)").font(Theme.engraved(13)).foregroundStyle(Theme.ember)
                }
                ProgressView(value: Double(unlocked), total: Double(max(1, achievements.count)))
                    .tint(Theme.blood)
                Toggle("Show locked", isOn: $showLocked).font(Theme.serif(15)).tint(Theme.crimson)
                let list = achievements
                    .filter { showLocked || $0.achieved }
                    .sorted { a, b in
                        if a.achieved != b.achieved { return a.achieved }
                        if a.achieved { return (a.unlocked ?? .distantPast) > (b.unlocked ?? .distantPast) }
                        return (a.globalPercent ?? 0) > (b.globalPercent ?? 0)
                    }
                ForEach(list) { item in
                    HStack(spacing: 12) {
                        SteamImage(url: item.achieved ? item.icon : item.iconGray)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(item.achieved ? Theme.blood : Theme.line))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(Theme.serif(15, weight: .semibold))
                                .foregroundStyle(item.achieved ? Theme.bone : Theme.ash)
                            Text(item.hidden && !item.achieved ? "Hidden until unlocked" : item.detail)
                                .font(Theme.serifItalic(13))
                                .foregroundStyle(Theme.ash)
                                .lineLimit(2)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let percent = item.globalPercent {
                                Text(String(format: "%.1f%%", percent))
                                    .font(Theme.engraved(11))
                                    .foregroundStyle(percent < 10 ? Theme.ember : Theme.ash)
                            }
                            if let date = item.unlocked {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(Theme.engraved(9)).foregroundStyle(Theme.ash)
                            }
                        }
                    }
                    .opacity(item.achieved ? 1 : 0.75)
                }
            }
        } else {
            ProgressView().tint(Theme.blood).frame(maxWidth: .infinity)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.engraved(10)).tracking(1.5).foregroundStyle(Theme.ash)
            Text(value).font(Theme.serif(16, weight: .semibold)).foregroundStyle(Theme.bone)
        }
    }
}

// MARK: Friends

struct CovenView: View {
    @EnvironmentObject private var store: HoardStore

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if store.friends.isEmpty {
                    VStack(spacing: 12) {
                        Text("✠").font(.system(size: 34)).foregroundStyle(Theme.crimson)
                        Text("A solitary vigil").font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                        Text(store.friendsError ?? "No friends to show.")
                            .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else {
                    List {
                        let online = store.friends.filter(\.isOnline)
                        let offline = store.friends.filter { !$0.isOnline }
                        if !online.isEmpty {
                            Section { ForEach(online) { FriendRow(player: $0) } } header: { header("AWAKE · \(online.count)") }
                        }
                        if !offline.isEmpty {
                            Section { ForEach(offline) { FriendRow(player: $0) } } header: { header("SLUMBERING · \(offline.count)") }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.refreshFriends() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Coven")
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.engraved(12)).tracking(2).foregroundStyle(Theme.ash)
    }
}

struct FriendRow: View {
    @Environment(\.openURL) private var openURL
    let player: Player

    var body: some View {
        Button {
            if let link = player.profileurl.flatMap(URL.init(string:)) { openURL(link) }
        } label: {
            HStack(spacing: 12) {
                SteamImage(url: player.avatar)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(player.isInGame ? Theme.blood : (player.isOnline ? Theme.ember.opacity(0.6) : Theme.line), lineWidth: player.isInGame ? 2 : 1))
                    .grayscale(player.isOnline ? 0 : 0.8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.personaname)
                        .font(Theme.serif(16, weight: .semibold))
                        .foregroundStyle(player.isOnline ? Theme.bone : Theme.ash)
                    Text(player.status)
                        .font(Theme.serifItalic(13))
                        .foregroundStyle(player.isInGame ? Theme.ember : Theme.ash)
                        .lineLimit(1)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.line)
    }
}

// MARK: Wishlist

struct CovetView: View {
    @EnvironmentObject private var store: HoardStore
    @Environment(\.openURL) private var openURL
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if store.wishlist.isEmpty {
                    VStack(spacing: 12) {
                        if store.loadingWishlist { ProgressView().tint(Theme.blood).scaleEffect(1.4) }
                        Text(store.loadingWishlist ? "Reading your desires" : "Nothing coveted")
                            .font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                        Text(loaded && !store.loadingWishlist ? "Your Steam wishlist is empty or private." : "Checking prices…")
                            .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                    }
                    .padding(30)
                } else {
                    List(store.wishlist) { entry in
                        Button {
                            openURL(Steam.storePage(entry.appid))
                        } label: {
                            HStack(spacing: 12) {
                                SteamImage(url: entry.header)
                                    .frame(width: 116, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name ?? "…")
                                        .font(Theme.serif(15, weight: .semibold))
                                        .foregroundStyle(Theme.bone)
                                        .lineLimit(2)
                                    if let added = entry.added {
                                        Text("Coveted since \(added.formatted(date: .abbreviated, time: .omitted))")
                                            .font(Theme.engraved(9)).foregroundStyle(Theme.ash)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    if let price = entry.price {
                                        if price.discount_percent > 0 {
                                            Text("−\(price.discount_percent)%").font(Theme.engraved(11)).foregroundStyle(Theme.bone)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Theme.crimson, in: RoundedRectangle(cornerRadius: 3))
                                        }
                                        Text(price.final_formatted).font(Theme.serif(15, weight: .semibold))
                                            .foregroundStyle(price.discount_percent > 0 ? Theme.ember : Theme.bone)
                                    } else {
                                        Text(entry.free ? "Free" : "—").font(Theme.serif(14)).foregroundStyle(Theme.ash)
                                    }
                                }
                            }
                        }
                        .listRowBackground((entry.price?.discount_percent ?? 0) > 0 ? Theme.crimson.opacity(0.14) : Color.clear)
                        .listRowSeparatorTint(Theme.line)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.refreshWishlist() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Covet")
            .task {
                if store.wishlist.isEmpty { await store.refreshWishlist() }
                loaded = true
            }
        }
    }
}

// MARK: Profile

struct ProfileView: View {
    @EnvironmentObject private var store: HoardStore
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        if let me = store.me {
                            SteamImage(url: me.avatar)
                                .frame(width: 120, height: 120)
                                .clipShape(ArchWindow())
                                .overlay(ArchWindow().stroke(Theme.blood, lineWidth: 2))
                                .shadow(color: Theme.crimson, radius: 16)
                                .padding(.top, 20)
                            Text(me.personaname).font(Theme.gothic(40)).foregroundStyle(Theme.bone)
                            Text(me.status).font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                        }
                        OrnamentDivider().padding(.horizontal, 30)
                        HStack(spacing: 0) {
                            tile("\(store.games.count)", "GAMES")
                            tile(Steam.hours(store.totalMinutes), "PLAYED")
                            tile("\(store.unplayedCount)", "UNPLAYED")
                            if let level = store.level { tile("\(level)", "LEVEL") }
                        }
                        if let top = store.games.max(by: { $0.minutes < $1.minutes }), top.minutes > 0 {
                            VStack(spacing: 6) {
                                Text("MOST DEVOTED TO").font(Theme.engraved(11)).tracking(2).foregroundStyle(Theme.ash)
                                SteamImage(url: top.header).aspectRatio(460.0 / 215.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
                                Text("\(top.title) · \(top.hoursText)").font(Theme.serif(15)).foregroundStyle(Theme.bone)
                            }
                            .padding(.horizontal, 24)
                        }
                        Button("Disconnect Steam") { confirm = true }
                            .buttonStyle(CrimsonButtonStyle(filled: false))
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                    }
                    .padding(.bottom, 30)
                }
                .refreshable { await store.refreshAll() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Sanctum")
            .confirmationDialog("Forget your API key and Steam ID on this iPhone?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { store.forget() }
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(Theme.serif(20, weight: .semibold)).foregroundStyle(Theme.ember)
            Text(label).font(Theme.engraved(9)).tracking(1.5).foregroundStyle(Theme.ash)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A pointed arch for the avatar frame.
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

// MARK: Setup

struct SetupView: View {
    @EnvironmentObject private var store: HoardStore
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var profile = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("✠").font(.system(size: 26)).foregroundStyle(Theme.blood).shadow(color: Theme.blood, radius: 12)
                        Text("Hoard")
                            .font(Theme.gothic(76))
                            .foregroundStyle(LinearGradient(colors: [Theme.bone, Theme.ember], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.crimson, radius: 18)
                        Text("YOUR STEAM, ENTOMBED").font(Theme.engraved(12)).tracking(4).foregroundStyle(Theme.ash)
                        OrnamentDivider().padding(.top, 10)
                    }
                    .padding(.top, 30)
                    InscribedField(label: "Steam Web API key", text: $key, prompt: "32 letters and numbers", secure: true)
                    Button("Get a key at steamcommunity.com/dev/apikey") {
                        openURL(URL(string: "https://steamcommunity.com/dev/apikey")!)
                    }
                    .font(Theme.serifItalic(14))
                    InscribedField(label: "Your Steam profile", text: $profile, prompt: "Profile link, custom URL name or 17-digit ID", keyboard: .URL)
                    Text("Find it in Steam → your name → Profile → Copy page URL. For the library and friends to show, set Game details and Friends list to Public in Edit Profile → Privacy Settings.")
                        .font(Theme.serifItalic(13)).foregroundStyle(Theme.ash)
                    if let error {
                        Text(error).font(Theme.serif(15)).foregroundStyle(Theme.ember).multilineTextAlignment(.center)
                    }
                    Button {
                        Task {
                            working = true
                            defer { working = false }
                            do { try await store.configure(key: key, profile: profile) } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack { if working { ProgressView().tint(Theme.bone) }; Text(working ? "Unsealing…" : "Open the Hoard") }
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    .disabled(working || key.isEmpty || profile.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
