import SwiftUI

// MARK: Chronicle: everything, newest first, by month

struct ChronicleView: View {
    @EnvironmentObject private var store: GalleryStore
    @AppStorage("reliquary.columns") private var columns = 4
    @State private var viewer: ViewerContext?
    @State private var query = ""

    private var shown: [MediaItem] { store.searchResults ?? store.timeline }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if shown.isEmpty {
                    ScrollView {
                        EmptyCrypt(
                            title: store.searchResults != nil ? "Nothing found" : (store.loadingTimeline || store.searching ? "Opening the reliquary" : "The reliquary is empty"),
                            message: store.searchResults != nil
                                ? "No file or folder names match."
                                : (store.loadingTimeline ? "Gathering your relics…" : emptyMessage),
                            loading: store.loadingTimeline || store.searching
                        )
                        .padding(.top, 100)
                    }
                    .refreshable { await store.reloadTimeline() }
                } else {
                    grid
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle(store.searchResults != nil ? "Search" : "Chronicle")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $store.filter) {
                            ForEach(KindFilter.allCases) { kind in
                                Label(kind.label, systemImage: kind.symbol).tag(kind)
                            }
                        }
                        Section("Columns") {
                            Button { withAnimation { columns = max(1, columns - 1) } } label: { Label("Larger", systemImage: "plus.magnifyingglass") }
                            Button { withAnimation { columns = min(7, columns + 1) } } label: { Label("Smaller", systemImage: "minus.magnifyingglass") }
                        }
                    } label: {
                        Image(systemName: store.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search names and folders"))
            .onSubmit(of: .search) { Task { await store.search(query) } }
            .onChange(of: query) { _, value in if value.isEmpty { store.clearSearch() } }
            .fullScreenCover(item: $viewer) { context in
                ViewerView(context: context)
                    .environmentObject(store)
            }
            .task {
                if store.timeline.isEmpty { await store.reloadTimeline() }
            }
        }
    }

    private var emptyMessage: String {
        if store.status?.scanning == true { return "The server is still cataloguing your IDrive-Sync folder. Pull down in a minute." }
        return "No photos or videos were found in the IDrive-Sync folder."
    }

    private var grid: some View {
        let sections = GalleryStore.sections(shown)
        let all = shown
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let status = store.status, store.searchResults == nil {
                    Text("\(status.images) photos · \(status.videos) videos" + (status.scanning ? " · cataloguing…" : ""))
                        .font(Theme.engraved(11))
                        .tracking(1.5)
                        .foregroundStyle(Theme.ash)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                ForEach(sections) { section in
                    Section {
                        LazyVGrid(columns: gridColumns(columns), spacing: 2) {
                            ForEach(section.items) { item in
                                Button {
                                    viewer = ViewerContext(items: all, start: all.firstIndex(of: item) ?? 0)
                                } label: {
                                    MediaCell(item: item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { favoriteButton(item) }
                                .onAppear {
                                    if item.path == all.last?.path, store.searchResults == nil {
                                        Task { await store.loadMoreTimeline() }
                                    }
                                }
                            }
                        }
                    } header: {
                        MonthHeader(title: section.title, count: section.items.count)
                    }
                }
                if store.loadingTimeline, !store.timeline.isEmpty {
                    ProgressView().tint(Theme.blood).frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.bottom, 20)
        }
        .pinchColumns($columns)
        .refreshable { await store.reloadTimeline() }
    }

    @ViewBuilder
    private func favoriteButton(_ item: MediaItem) -> some View {
        Button {
            Task { await store.toggleFavorite(item) }
        } label: {
            Label(store.isFavorite(item) ? "Remove from Relics" : "Add to Relics", systemImage: store.isFavorite(item) ? "heart.slash" : "heart")
        }
    }
}

// MARK: Catacombs: the folders

struct CatacombsView: View {
    var body: some View {
        NavigationStack {
            FolderView(path: "", title: "Catacombs")
                .navigationDestination(for: FolderEntry.self) { folder in
                    FolderView(path: folder.path, title: folder.name)
                }
        }
    }
}

struct FolderView: View {
    @EnvironmentObject private var store: GalleryStore
    @AppStorage("reliquary.columns") private var columns = 4
    let path: String
    let title: String

    @State private var listing: Listing?
    @State private var error: String?
    @State private var viewer: ViewerContext?

    private let folderColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            GothicBackground()
            if let listing {
                if listing.folders.isEmpty && listing.items.isEmpty {
                    EmptyCrypt(title: "An empty tomb", message: "No photos or videos rest in this folder.")
                } else {
                    content(listing)
                }
            } else if let error {
                ScrollView {
                    EmptyCrypt(title: "Sealed", message: error)
                        .padding(.top, 100)
                }
                .refreshable { await load() }
            } else {
                EmptyCrypt(title: "Descending", message: "Lighting the torches…", loading: true)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .gothicTitle(title)
        .fullScreenCover(item: $viewer) { context in
            ViewerView(context: context)
                .environmentObject(store)
        }
        .task { if listing == nil { await load() } }
    }

    private func load() async {
        do {
            listing = try await store.listing(path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func content(_ listing: Listing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !listing.folders.isEmpty {
                    LazyVGrid(columns: folderColumns, spacing: 18) {
                        ForEach(listing.folders) { folder in
                            NavigationLink(value: folder) {
                                FolderCard(folder: folder)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                if !listing.items.isEmpty {
                    if !listing.folders.isEmpty {
                        OrnamentDivider().padding(.horizontal, 30)
                    }
                    LazyVGrid(columns: gridColumns(columns), spacing: 2) {
                        ForEach(Array(listing.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                viewer = ViewerContext(items: listing.items, start: index)
                            } label: {
                                MediaCell(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .pinchColumns($columns)
        .refreshable { await load() }
    }
}

/// A folder shown as a gothic window with its newest picture inside.
struct FolderCard: View {
    @EnvironmentObject private var store: GalleryStore
    let folder: FolderEntry

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.clear
                    .aspectRatio(0.78, contentMode: .fit)
                    .overlay(Thumbnail(url: folder.cover.flatMap { store.client?.thumbURL($0) }))
                    .clipShape(ArchShape())
                ArchShape()
                    .stroke(LinearGradient(colors: [Theme.blood, Theme.crimson], startPoint: .top, endPoint: .bottom), lineWidth: 2)
                ArchShape()
                    .stroke(Theme.bone.opacity(0.15), lineWidth: 1)
                    .padding(5)
            }
            .shadow(color: Theme.crimson.opacity(0.45), radius: 10)
            Text(folder.name)
                .font(Theme.serif(16, weight: .semibold))
                .foregroundStyle(Theme.bone)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(folder.count == 1 ? "1 relic" : "\(folder.count) relics")
                .font(Theme.engraved(10))
                .tracking(1)
                .foregroundStyle(Theme.ash)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Relics: favourites

struct RelicsView: View {
    @EnvironmentObject private var store: GalleryStore
    @AppStorage("reliquary.columns") private var columns = 4
    @State private var viewer: ViewerContext?
    @State private var loaded = false

    private var items: [MediaItem] { store.favorites.filter { store.isFavorite($0) } }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if items.isEmpty {
                    ScrollView {
                        EmptyCrypt(
                            title: loaded ? "No relics yet" : "Unsealing",
                            message: loaded ? "Tap the heart on a photo or video to keep it here." : "Gathering your relics…",
                            loading: !loaded
                        )
                        .padding(.top, 100)
                    }
                    .refreshable { await store.loadFavorites() }
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns(columns), spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    viewer = ViewerContext(items: items, start: index)
                                } label: {
                                    MediaCell(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .pinchColumns($columns)
                    .refreshable { await store.loadFavorites() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Relics")
            .fullScreenCover(item: $viewer) { context in
                ViewerView(context: context)
                    .environmentObject(store)
            }
            .task {
                await store.loadFavorites()
                loaded = true
            }
        }
    }
}

// MARK: Sanctum: settings

struct SanctumView: View {
    @EnvironmentObject private var store: GalleryStore
    @State private var confirmForget = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    Section {
                        if let status = store.status {
                            stat("Photos", "\(status.images)")
                            stat("Videos", "\(status.videos)")
                            stat("Relics", "\(status.favorites)")
                            stat("Last catalogued", status.scanning ? "Cataloguing now…" : (status.lastScan.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"))
                        } else {
                            Text("Fetching…").font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                        }
                        Button {
                            Task { await store.rescan() }
                        } label: {
                            Text("Look for new photos now").font(Theme.engraved(14)).foregroundStyle(Theme.ember)
                        }
                    } header: {
                        header("THE RELIQUARY")
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        stat("Server", store.address)
                        Button {
                            Task {
                                await ImageLoader.shared.clear()
                                cleared = true
                            }
                        } label: {
                            Text(cleared ? "Thumbnail cache cleared" : "Clear thumbnail cache")
                                .font(Theme.engraved(14))
                                .foregroundStyle(cleared ? Theme.ash : Theme.ember)
                        }
                        Button(role: .destructive) {
                            confirmForget = true
                        } label: {
                            Text("Disconnect from server").font(Theme.engraved(14)).foregroundStyle(Theme.ember)
                        }
                    } header: {
                        header("CONNECTION")
                    } footer: {
                        Text("Reliquary only reads your IDrive-Sync folder. It can't change or delete anything there.")
                            .font(Theme.serifItalic(12))
                            .foregroundStyle(Theme.ash.opacity(0.8))
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await store.refreshStatus() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Sanctum")
            .task { await store.refreshStatus() }
            .confirmationDialog("Disconnect from this server? Your photos stay on the NAS.", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { store.forget() }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.engraved(12)).tracking(2).foregroundStyle(Theme.ash)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.serif(16)).foregroundStyle(Theme.bone)
            Spacer()
            Text(value).font(Theme.engraved(13)).foregroundStyle(Theme.ash).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Setup

struct SetupView: View {
    @EnvironmentObject private var store: GalleryStore
    @State private var address = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 6) {
                        Text("✠")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.blood)
                            .shadow(color: Theme.blood, radius: 12)
                        Text("Reliquary")
                            .font(Theme.gothic(64))
                            .foregroundStyle(LinearGradient(colors: [Theme.bone, Theme.ember], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.crimson, radius: 18)
                        Text("YOUR IDRIVE-SYNC, ENSHRINED")
                            .font(Theme.engraved(12))
                            .tracking(3)
                            .foregroundStyle(Theme.ash)
                        OrnamentDivider().padding(.top, 10)
                    }
                    .padding(.top, 30)

                    VStack(spacing: 22) {
                        InscribedField(label: "Server", text: $address, prompt: "http://100.x.y.z:8788", keyboard: .URL)
                        InscribedField(label: "Token", text: $token, prompt: "GALLERY_TOKEN from the server's YAML", secure: true)
                        Text("Install the Reliquary server on TrueNAS first (see reliquary-server/README.md), and keep Tailscale on.")
                            .font(Theme.serifItalic(14))
                            .foregroundStyle(Theme.ash)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let error {
                        Text(error)
                            .font(Theme.serif(15))
                            .foregroundStyle(Theme.ember)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Theme.crimson.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        HStack(spacing: 10) {
                            if working { ProgressView().tint(Theme.bone) }
                            Text(working ? "Unsealing…" : "Open the Reliquary")
                        }
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    .disabled(working || address.isEmpty || token.isEmpty)
                    .opacity(address.isEmpty || token.isEmpty ? 0.5 : 1)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await store.connect(address: address, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
