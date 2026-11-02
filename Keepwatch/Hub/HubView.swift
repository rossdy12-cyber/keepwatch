import SwiftUI

struct HubView: View {
    enum SectionTab: String, CaseIterable, Identifiable {
        case chronicle = "Chronicle"
        case nightPicker = "Night Picker"
        case store = "Store Admin"
        var id: String { rawValue }
    }

    @EnvironmentObject private var hub: HubStore
    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var router: AppRouter
    @State private var section: SectionTab = .chronicle
    @State private var showingAddHandover = false
    @State private var showingAddPick = false
    @State private var pickedItem: NightPickItem?
    @State private var productSearch = ""
    @State private var openWeb: WebDestination?

    private let headStylePresets = ["Race Spec", "Flanged Hex", "Tapered Socket", "Titanium"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(SectionTab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch section {
                        case .chronicle:
                            chronicleContent
                        case .nightPicker:
                            nightPickerContent
                        case .store:
                            storeAdminContent
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .keepwatchChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    switch section {
                    case .chronicle:
                        Button {
                            showingAddHandover = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    case .nightPicker:
                        Button {
                            showingAddPick = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    case .store:
                        if let url = URL(string: hub.wooConfig.baseURL + "/wp-admin"), !hub.wooConfig.baseURL.isEmpty {
                            Button {
                                openWeb = WebDestination(title: "WP Admin", url: url)
                            } label: {
                                Label("WP-Admin", systemImage: "globe")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddHandover) {
                AddHandoverSheet()
            }
            .sheet(isPresented: $showingAddPick) {
                AddPickSheet()
            }
            .fullScreenCover(item: $openWeb) { dest in
                WebScreen(destination: dest, showsDone: true)
            }
        }
    }

    // MARK: - 1. Gothic Chronicle & Handover Schedule

    private var chronicleContent: some View {
        let doneCount = hub.handoverItems.filter(\.completed).count
        return Group {
            VStack(spacing: 6) {
                Text("CHRONICLE OF COMPLETION & DELIVERY")
                    .font(.caption2.weight(.bold))
                    .tracking(2.5)
                    .foregroundStyle(Theme.gothicPurple)
                Text("Schedule of Notes & Handover")
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                Text("Prepared for Lauren · \(doneCount) of \(hub.handoverItems.count) completed")
                    .font(.caption.italic())
                    .foregroundStyle(Theme.gothicCrimson)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.14, green: 0.04, blue: 0.10), Color(red: 0.07, green: 0.04, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.gothicCrimson.opacity(0.7), lineWidth: 1.5)
            )

            ForEach($hub.handoverItems) { $item in
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        item.completed.toggle()
                    } label: {
                        Image(systemName: item.completed ? "checkmark.seal.fill" : "diamond")
                            .font(.title3)
                            .foregroundStyle(item.completed ? Theme.good : Theme.gothicCrimson)
                            .padding(.top, 2)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(.system(.headline, design: .serif))
                            .strikethrough(item.completed)
                            .foregroundStyle(item.completed ? Theme.secondaryText : .white)
                        if !item.detail.isEmpty {
                            Text(item.detail)
                                .font(.subheadline.italic())
                                .foregroundStyle(Theme.secondaryText)
                        }
                        HStack(spacing: 8) {
                            Text(item.targetDay.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.gothicCrimson.opacity(0.25), in: Capsule())
                                .overlay(Capsule().stroke(Theme.gothicCrimson, lineWidth: 1))
                            Text(item.targetTime)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.gothicPurple.opacity(0.22), in: Capsule())
                                .overlay(Capsule().stroke(Theme.gothicPurple.opacity(0.6), lineWidth: 1))
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        hub.handoverItems.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.gothicPurple.opacity(0.28), lineWidth: 1)
                )
            }

            HStack {
                Button("Restore Original Handover Schedule") {
                    hub.resetHandover()
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 2. Spooky / Gamer Night Picker

    private var nightPickerContent: some View {
        let games = hub.picks.filter { $0.category == .game }
        let movies = hub.picks.filter { $0.category == .movie }

        return Group {
            HStack(spacing: 10) {
                Button {
                    pickedItem = games.filter { !$0.watchedOrPlayed }.randomElement() ?? games.randomElement()
                } label: {
                    Label("Pick a Game", systemImage: "gamecontroller.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.gothicPurple, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    pickedItem = movies.filter { !$0.watchedOrPlayed }.randomElement() ?? movies.randomElement()
                } label: {
                    Label("Pick a Horror", systemImage: "film.stack.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.gothicCrimson, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if let picked = pickedItem {
                Card(title: "Tonight's Pick", symbol: "sparkles", trailing: picked.category.rawValue) {
                    Text(picked.title)
                        .font(.title3.weight(.bold))
                    Text(picked.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    if picked.category == .movie {
                        Button {
                            Task {
                                await hub.sendMovieToRadarr(title: picked.title, radarrConfig: settings[.radarr])
                            }
                        } label: {
                            Label("Grab in Radarr", systemImage: "arrow.down.circle.fill")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.gothicCrimson)
                    }
                }
            }

            if let status = hub.radarrStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 4)
            }

            Card(title: "Co-Op & Spooky Games", symbol: "gamecontroller", trailing: "\(games.count)") {
                ForEach(games) { item in
                    pickRow(item)
                }
            }

            Card(title: "Jumpscare Horror Watchlist", symbol: "film", trailing: "\(movies.count)") {
                ForEach(movies) { item in
                    pickRow(item)
                }
            }
        }
    }

    private func pickRow(_ item: NightPickItem) -> some View {
        HStack(spacing: 10) {
            Button {
                if let idx = hub.picks.firstIndex(where: { $0.id == item.id }) {
                    hub.picks[idx].watchedOrPlayed.toggle()
                }
            } label: {
                Image(systemName: item.watchedOrPlayed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.watchedOrPlayed ? Theme.good : Theme.secondaryText)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(item.watchedOrPlayed)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if item.category == .movie {
                Button {
                    Task {
                        await hub.sendMovieToRadarr(title: item.title, radarrConfig: settings[.radarr])
                    }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Grab \(item.title) in Radarr")
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 3. WooCommerce Store Admin

    @ViewBuilder
    private var storeAdminContent: some View {
        if !hub.wooConfig.isConfigured {
            MessageCard(
                symbol: "bag.fill",
                title: "Connect Your WordPress Store",
                message: "Add your store URL and WooCommerce REST API keys in Settings to quickly toggle products (Race Spec, Flanged Hex, Tapered Socket) between Published and Private.",
                color: Theme.accent,
                actionTitle: "Open Settings"
            ) {
                router.tab = .settings
            }
        } else {
            HStack(spacing: 8) {
                TextField("Search products (e.g. Race Spec)…", text: $productSearch)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit {
                        Task { await hub.fetchProducts(search: productSearch) }
                    }
                Button {
                    Task { await hub.fetchProducts(search: productSearch) }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .padding(10)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Theme.background)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("All") {
                        productSearch = ""
                        Task { await hub.fetchProducts(search: "") }
                    }
                    .buttonStyle(.bordered)
                    ForEach(headStylePresets, id: \.self) { preset in
                        Button(preset) {
                            productSearch = preset
                            Task { await hub.fetchProducts(search: preset) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let error = hub.storeError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }

            if hub.isLoadingProducts {
                ProgressView("Loading products…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else if hub.products.isEmpty {
                Card(title: "Store Products", symbol: "shippingbox") {
                    Text("Tap search or one of the head style filters above to load products from your store.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    Button("Load Products") {
                        Task { await hub.fetchProducts(search: productSearch) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Card(title: "Products", symbol: "shippingbox.fill", trailing: "\(hub.products.count)") {
                    ForEach(hub.products) { product in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(product.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Pill(
                                        text: product.status.uppercased(),
                                        color: product.status == "publish" ? Theme.good : Theme.warning
                                    )
                                    if !product.price.isEmpty {
                                        Text("£\(product.price)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                            Spacer()
                            Menu {
                                Button("Published (Visible)") {
                                    Task { await hub.updateProductStatus(product, newStatus: "publish") }
                                }
                                Button("Private (Hidden)") {
                                    Task { await hub.updateProductStatus(product, newStatus: "private") }
                                }
                                Button("Draft") {
                                    Task { await hub.updateProductStatus(product, newStatus: "draft") }
                                }
                            } label: {
                                Label("Status", systemImage: "eye.circle")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.surfaceRaised, in: Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

struct AddHandoverSheet: View {
    @EnvironmentObject private var hub: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var day = "Monday"
    @State private var time = "9:00 PM"

    private let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry Details") {
                    TextField("Title of Note / Entry", text: $title)
                    TextField("Description / Evidence note", text: $detail)
                }
                Section("Handover Schedule") {
                    Picker("Target Day", selection: $day) {
                        ForEach(days, id: \.self) { d in Text(d).tag(d) }
                    }
                    TextField("Appointed Hour (e.g. 10:00 PM)", text: $time)
                }
            }
            .scrollContentBackground(.hidden)
            .keepwatchChrome()
            .navigationTitle("Add Handover Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        hub.handoverItems.append(
                            HandoverItem(
                                title: title.trimmingCharacters(in: .whitespaces),
                                detail: detail.trimmingCharacters(in: .whitespaces),
                                targetDay: day,
                                targetTime: time.trimmingCharacters(in: .whitespaces)
                            )
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct AddPickSheet: View {
    @EnvironmentObject private var hub: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var subtitle = ""
    @State private var category: NightPickItem.Category = .movie

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $category) {
                        ForEach(NightPickItem.Category.allCases, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    TextField("Title", text: $title)
                    TextField("Notes / Platform / Vibe", text: $subtitle)
                }
            }
            .scrollContentBackground(.hidden)
            .keepwatchChrome()
            .navigationTitle("Add to Watchlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        hub.picks.append(
                            NightPickItem(
                                title: title.trimmingCharacters(in: .whitespaces),
                                subtitle: subtitle.trimmingCharacters(in: .whitespaces),
                                category: category
                            )
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
