import SwiftUI

// MARK: Shared pieces

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let result = try? await DealsAPI.imageSession.data(from: url), let loaded = UIImage(data: result.0) {
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
    }
}

struct DealRow: View {
    @EnvironmentObject private var store: TitheStore
    let deal: Deal

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: DealsAPI.steamHeader(deal.steamAppID) ?? deal.thumb.flatMap(URL.init(string:)))
                .frame(width: 116, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            VStack(alignment: .leading, spacing: 4) {
                Text(deal.title)
                    .font(Theme.serif(16, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let s = store.store(deal.storeID) {
                        RemoteImage(url: s.iconURL, contentMode: .fit).frame(width: 14, height: 14)
                        Text(s.storeName).font(Theme.engraved(10)).foregroundStyle(Theme.ash).lineLimit(1)
                    }
                    if let score = deal.metacritic {
                        Text("MC \(score)").font(Theme.engraved(10)).foregroundStyle(Theme.ash)
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text("−\(deal.percentOff)%")
                    .font(Theme.engraved(12))
                    .foregroundStyle(Theme.bone)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.crimson, in: RoundedRectangle(cornerRadius: 3))
                Text(store.price(deal.sale))
                    .font(Theme.serif(16, weight: .semibold))
                    .foregroundStyle(Theme.ember)
                Text(store.price(deal.normal))
                    .font(Theme.serif(12))
                    .strikethrough()
                    .foregroundStyle(Theme.ash)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Offerings

struct OfferingsView: View {
    @EnvironmentObject private var store: TitheStore
    @AppStorage("tithe.sort") private var sort: SortOrder = .rating
    @AppStorage("tithe.maxPrice") private var maxPrice = 0
    @AppStorage("tithe.aaa") private var onlyAAA = false
    @AppStorage("tithe.stores") private var storeFilter = ""
    @State private var deals: [Deal] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var showFilters = false
    @State private var error: String?

    private var storeSet: Set<String> { Set(storeFilter.split(separator: ",").map(String.init)) }
    private var filterKey: String { "\(sort.rawValue)|\(maxPrice)|\(onlyAAA)|\(storeFilter)" }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if deals.isEmpty {
                    VStack(spacing: 12) {
                        if loading {
                            ProgressView().tint(Theme.blood).scaleEffect(1.4)
                        } else {
                            Text("✠").font(.system(size: 34)).foregroundStyle(Theme.crimson)
                        }
                        Text(loading ? "Counting the coffers" : (error == nil ? "No offerings" : "The coffers are sealed"))
                            .font(Theme.gothic(30)).foregroundStyle(Theme.bone)
                        Text(error ?? (loading ? "Gathering deals…" : "Nothing matches these filters."))
                            .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else {
                    List {
                        ForEach(deals) { deal in
                            NavigationLink(value: deal) { DealRow(deal: deal) }
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.line)
                                .onAppear {
                                    if deal.id == deals.last?.id { Task { await load(reset: false) } }
                                }
                        }
                        if loading {
                            ProgressView().tint(Theme.blood).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load(reset: true) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Offerings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Sort and filter")
                }
            }
            .navigationDestination(for: Deal.self) { deal in
                GameDetailView(gameID: deal.gameID, fallbackTitle: deal.title, steamAppID: deal.steamAppID)
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet(sort: $sort, maxPrice: $maxPrice, onlyAAA: $onlyAAA, storeFilter: $storeFilter)
                    .presentationDetents([.large])
                    .presentationBackground(Theme.void)
            }
            .task(id: filterKey) { await load(reset: true) }
        }
    }

    private func load(reset: Bool) async {
        if loading && !reset { return }
        if !reset && page + 1 >= pages { return }
        loading = true
        defer { loading = false }
        let next = reset ? 0 : page + 1
        do {
            let result = try await DealsAPI.deals(page: next, sort: sort, stores: storeSet, maxPrice: maxPrice > 0 ? maxPrice : nil, onlyAAA: onlyAAA, title: nil)
            if reset { deals = [] }
            let known = Set(deals.map(\.id))
            deals += result.deals.filter { !known.contains($0.id) }
            page = next
            pages = result.pages
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
        }
    }
}

struct FilterSheet: View {
    @EnvironmentObject private var store: TitheStore
    @Environment(\.dismiss) private var dismiss
    @Binding var sort: SortOrder
    @Binding var maxPrice: Int
    @Binding var onlyAAA: Bool
    @Binding var storeFilter: String

    private var selected: Set<String> { Set(storeFilter.split(separator: ",").map(String.init)) }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                Form {
                    Section("Order") {
                        Picker("Sort by", selection: $sort) {
                            ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    .listRowBackground(Theme.surface)
                    Section("Price") {
                        Picker("Under", selection: $maxPrice) {
                            Text("Any price").tag(0)
                            ForEach([1, 5, 10, 15, 20, 30, 40], id: \.self) { Text("$\($0)").tag($0) }
                        }
                        Toggle("Big releases only (AAA)", isOn: $onlyAAA)
                    }
                    .listRowBackground(Theme.surface)
                    Section {
                        ForEach(store.stores) { shop in
                            Button {
                                var set = selected
                                if set.contains(shop.storeID) { set.remove(shop.storeID) } else { set.insert(shop.storeID) }
                                storeFilter = set.sorted().joined(separator: ",")
                            } label: {
                                HStack(spacing: 10) {
                                    RemoteImage(url: shop.iconURL, contentMode: .fit).frame(width: 18, height: 18)
                                    Text(shop.storeName).foregroundStyle(Theme.bone)
                                    Spacer()
                                    if selected.contains(shop.storeID) {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.blood)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Stores")
                    } footer: {
                        Text(selected.isEmpty ? "All stores are included." : "Only the ticked stores are shown.")
                    }
                    .listRowBackground(Theme.surface)
                }
                .font(Theme.serif(16))
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { sort = .rating; maxPrice = 0; onlyAAA = false; storeFilter = "" }
                        .font(Theme.engraved(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(Theme.engraved(14))
                }
            }
        }
    }
}

// MARK: Seek

struct SeekView: View {
    @State private var query = ""
    @State private var results: [GameSearchResult] = []
    @State private var searching = false
    @State private var searched = false
    @EnvironmentObject private var store: TitheStore

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if results.isEmpty {
                    VStack(spacing: 12) {
                        if searching { ProgressView().tint(Theme.blood).scaleEffect(1.4) }
                        Text(searched && !searching ? "Nothing found" : "Seek a game")
                            .font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                        Text("Search every store's price at once.")
                            .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                    }
                } else {
                    List(results) { game in
                        NavigationLink(value: game) {
                            HStack(spacing: 12) {
                                RemoteImage(url: DealsAPI.steamHeader(game.steamAppID) ?? game.thumb.flatMap(URL.init(string:)))
                                    .frame(width: 116, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(game.external)
                                    .font(Theme.serif(16, weight: .semibold))
                                    .foregroundStyle(Theme.bone)
                                    .lineLimit(2)
                                Spacer()
                                Text("from " + store.price(Double(game.cheapest) ?? 0))
                                    .font(Theme.serif(14))
                                    .foregroundStyle(Theme.ember)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.line)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Seek")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Game title"))
            .onSubmit(of: .search) { Task { await search() } }
            .navigationDestination(for: GameSearchResult.self) { game in
                GameDetailView(gameID: game.gameID, fallbackTitle: game.external, steamAppID: game.steamAppID)
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false; searched = true }
        results = (try? await DealsAPI.search(text)) ?? []
    }
}

// MARK: Game

struct GameDetailView: View {
    @EnvironmentObject private var store: TitheStore
    @Environment(\.openURL) private var openURL
    let gameID: String
    let fallbackTitle: String
    let steamAppID: String?
    @State private var detail: GameDetail?
    @State private var error: String?
    @State private var showWatch = false

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RemoteImage(url: DealsAPI.steamHeader(detail?.info.steamAppID ?? steamAppID) ?? detail?.info.thumb.flatMap(URL.init(string:)))
                        .aspectRatio(460.0 / 215.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
                        .shadow(color: Theme.crimson.opacity(0.5), radius: 12)
                    Text(detail?.info.title ?? fallbackTitle)
                        .font(Theme.serif(26, weight: .semibold))
                        .foregroundStyle(Theme.bone)
                    if let ever = detail?.cheapestPriceEver {
                        Label("Lowest ever: \(store.price(Double(ever.price) ?? 0)) on \(Date(timeIntervalSince1970: ever.date).formatted(date: .abbreviated, time: .omitted))", systemImage: "crown")
                            .font(Theme.serifItalic(15))
                            .foregroundStyle(Theme.ash)
                    }
                    Button {
                        showWatch = true
                    } label: {
                        Label(store.isWatched(gameID) ? "Watching · change target" : "Keep vigil for a lower price", systemImage: "eye")
                    }
                    .buttonStyle(CrimsonButtonStyle(filled: !store.isWatched(gameID)))
                    OrnamentDivider()
                    if let detail {
                        ForEach(detail.deals.sorted { $0.priceValue < $1.priceValue }) { offer in
                            Button {
                                openURL(DealsAPI.redirect(offer.dealID))
                            } label: {
                                HStack(spacing: 12) {
                                    RemoteImage(url: store.store(offer.storeID)?.iconURL, contentMode: .fit).frame(width: 22, height: 22)
                                    Text(store.store(offer.storeID)?.storeName ?? "Store \(offer.storeID)")
                                        .font(Theme.serif(17))
                                        .foregroundStyle(Theme.bone)
                                    Spacer()
                                    if offer.percentOff > 0 {
                                        Text("−\(offer.percentOff)%")
                                            .font(Theme.engraved(11))
                                            .foregroundStyle(Theme.bone)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Theme.crimson, in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    Text(store.price(offer.priceValue))
                                        .font(Theme.serif(17, weight: .semibold))
                                        .foregroundStyle(Theme.ember)
                                    Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Theme.ash)
                                }
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Prices come from CheapShark in US dollars; other currencies are estimates. The store shows the real price.")
                            .font(Theme.serifItalic(12))
                            .foregroundStyle(Theme.ash.opacity(0.8))
                    } else if let error {
                        Text(error).font(Theme.serif(15)).foregroundStyle(Theme.ember)
                    } else {
                        ProgressView().tint(Theme.blood).frame(maxWidth: .infinity)
                    }
                }
                .padding(18)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await DealsAPI.game(gameID) } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showWatch) {
            WatchSheet(
                gameID: gameID,
                title: detail?.info.title ?? fallbackTitle,
                steamAppID: detail?.info.steamAppID ?? steamAppID,
                thumb: detail?.info.thumb,
                currentUSD: detail?.deals.map(\.priceValue).min()
            )
            .presentationDetents([.medium])
            .presentationBackground(Theme.void)
        }
    }
}

struct WatchSheet: View {
    @EnvironmentObject private var store: TitheStore
    @Environment(\.dismiss) private var dismiss
    let gameID: String
    let title: String
    let steamAppID: String?
    let thumb: String?
    let currentUSD: Double?
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep vigil").font(Theme.gothic(34)).foregroundStyle(Theme.bone)
            Text("Tithe checks this game's price in the background and tells you when any store sells it at or below your target.")
                .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
            if let currentUSD {
                Text("Now: \(store.price(currentUSD))").font(Theme.serif(16)).foregroundStyle(Theme.bone)
            }
            InscribedField(label: "Target price (\(store.currency.symbol))", text: $target, prompt: "e.g. 10", keyboard: .decimalPad)
            Button("Keep vigil") {
                guard let value = Double(target.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return }
                store.watch(gameID: gameID, title: title, steamAppID: steamAppID, thumb: thumb, targetUSD: store.usd(fromLocal: value), currentUSD: currentUSD)
                dismiss()
            }
            .buttonStyle(CrimsonButtonStyle())
            .disabled(Double(target.replacingOccurrences(of: ",", with: ".")) == nil)
            if store.isWatched(gameID) {
                Button("Stop watching", role: .destructive) {
                    store.unwatch(gameID)
                    dismiss()
                }
                .buttonStyle(CrimsonButtonStyle(filled: false))
            }
        }
        .padding(24)
        .onAppear {
            if let existing = store.watchlist.first(where: { $0.gameID == gameID }) {
                target = String(format: "%.2f", store.local(fromUSD: existing.target))
            } else if let currentUSD {
                target = String(format: "%.0f", max(1, (store.local(fromUSD: currentUSD) * 0.6).rounded()))
            }
        }
    }
}

// MARK: Vigil

struct VigilView: View {
    @EnvironmentObject private var store: TitheStore

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                if store.watchlist.isEmpty {
                    VStack(spacing: 12) {
                        Text("✠").font(.system(size: 34)).foregroundStyle(Theme.crimson)
                        Text("No vigils kept").font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                        Text("Open a game and tap “Keep vigil” to be told when it drops to your price.")
                            .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else {
                    List {
                        ForEach(store.watchlist) { item in
                            NavigationLink(value: item) {
                                HStack(spacing: 12) {
                                    RemoteImage(url: DealsAPI.steamHeader(item.steamAppID) ?? item.thumb.flatMap(URL.init(string:)))
                                        .frame(width: 100, height: 47)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(Theme.serif(16, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(2)
                                        Text("Target \(store.price(item.target))").font(Theme.engraved(11)).foregroundStyle(Theme.ash)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(item.lastPrice.map(store.price) ?? "–")
                                            .font(Theme.serif(16, weight: .semibold))
                                            .foregroundStyle(item.isHit ? Theme.ember : Theme.bone)
                                        if item.isHit {
                                            Text("REACHED").font(Theme.engraved(9)).tracking(1).foregroundStyle(Theme.blood)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(item.isHit ? Theme.crimson.opacity(0.18) : Color.clear)
                            .listRowSeparatorTint(Theme.line)
                        }
                        .onDelete { offsets in
                            offsets.map { store.watchlist[$0].gameID }.forEach(store.unwatch)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.refreshWatchlist() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Vigil")
            .navigationDestination(for: WatchItem.self) { item in
                GameDetailView(gameID: item.gameID, fallbackTitle: item.title, steamAppID: item.steamAppID)
            }
        }
    }
}

// MARK: Sanctum

struct SanctumView: View {
    @EnvironmentObject private var store: TitheStore

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                Form {
                    Section {
                        Picker("Show prices in", selection: $store.currency) {
                            ForEach(Currency.allCases) { Text("\($0.symbol) \($0.rawValue)").tag($0) }
                        }
                    } footer: {
                        Text("Deals are listed in US dollars. Pounds and euros are converted at today's rate, so they're close but not exact.")
                    }
                    .listRowBackground(Theme.surface)
                    Section {
                        if store.notificationsAllowed {
                            Label("Price alerts are on", systemImage: "bell.badge")
                        } else {
                            Button("Allow price alerts") { Task { await store.requestNotifications() } }
                        }
                    } footer: {
                        Text("iOS decides when Tithe can check in the background, usually every few hours. Prices also refresh whenever you open the app.")
                    }
                    .listRowBackground(Theme.surface)
                    Section {
                        Text("Deals and prices by CheapShark (cheapshark.com). Store links go through CheapShark.")
                    }
                    .listRowBackground(Theme.surface)
                }
                .font(Theme.serif(16))
                .foregroundStyle(Theme.bone)
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Sanctum")
        }
    }
}
