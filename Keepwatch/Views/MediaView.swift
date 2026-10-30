import SwiftUI

enum MediaSection: String, CaseIterable {
    case upcoming = "Upcoming"
    case missing = "Missing"
    case library = "Library"
}

struct MediaView: View {
    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var store: MediaStore
    @EnvironmentObject private var router: AppRouter

    @State private var section: MediaSection = .upcoming

    private var anyConfigured: Bool {
        MediaStore.services.contains { settings[$0].isConfigured }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Section", selection: $section) {
                        ForEach(MediaSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 4)

                    if !anyConfigured {
                        MessageCard(symbol: "film.stack", title: "Connect Sonarr, Radarr or Lidarr",
                                    message: "Add each app's address and API key in Settings.",
                                    color: Theme.accent, actionTitle: "Open Settings") { router.tab = .settings }
                    } else {
                        ForEach(MediaStore.services.filter { store.errors[$0] != nil }, id: \.self) { service in
                            Label("\(service.title): \(store.errors[service] ?? "")", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.warning)
                        }
                        if !store.loadedOnce {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            switch section {
                            case .upcoming: upcoming
                            case .missing: missing
                            case .library: library
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await store.refresh(settings) }
            .navigationTitle("Media")
            .keepwatchChrome()
        }
        .task(id: MediaStore.services.map { settings[$0] }) {
            if anyConfigured { await store.refresh(settings) }
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcoming: some View {
        let groups = Dictionary(grouping: store.upcoming) { item in
            Calendar.current.startOfDay(for: item.date ?? .distantFuture)
        }
        if store.upcoming.isEmpty {
            Text("Nothing scheduled in the next \(MediaStore.upcomingDays) days.")
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 8)
        }
        ForEach(groups.keys.sorted(), id: \.self) { day in
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: Format.day(day))
                ForEach(groups[day] ?? []) { item in
                    MediaRow(item: item, detail: item.service == .sonarr ? Format.time(item.date) : nil)
                }
            }
        }
    }

    // MARK: - Missing

    @ViewBuilder
    private var missing: some View {
        ForEach(MediaStore.services.filter { settings[$0].isConfigured }, id: \.self) { service in
            let items = store.missing[service] ?? []
            let total = store.missingTotals[service] ?? items.count
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: missingTitle(service), trailing: total > items.count ? "\(items.count) of \(total)" : "\(total)")
                if items.isEmpty {
                    Label("Nothing missing", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.good)
                        .font(.subheadline)
                }
                ForEach(items) { item in
                    MediaRow(item: item, detail: Format.relative(item.date))
                }
            }
        }
    }

    private func missingTitle(_ service: Service) -> String {
        switch service {
        case .sonarr: return "Episodes"
        case .radarr: return "Movies"
        default: return "Albums"
        }
    }

    // MARK: - Library

    private var library: some View {
        let stats = store.stats
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                if settings[.sonarr].isConfigured {
                    StatTile(title: "Series", value: "\(stats.seriesCount)", caption: Format.bytes(stats.seriesSize),
                             symbol: "tv", color: Theme.color(for: .sonarr))
                    StatTile(title: "Episodes", value: "\(stats.episodeFiles)",
                             caption: "of \(stats.episodesTotal) monitored",
                             symbol: "list.number", color: Theme.color(for: .sonarr),
                             fraction: stats.episodesTotal > 0 ? Double(stats.episodeFiles) / Double(stats.episodesTotal) : nil)
                }
                if settings[.radarr].isConfigured {
                    StatTile(title: "Movies", value: "\(stats.moviesDownloaded)",
                             caption: "of \(stats.movieCount) · \(Format.bytes(stats.movieSize))",
                             symbol: "film", color: Theme.color(for: .radarr),
                             fraction: stats.movieCount > 0 ? Double(stats.moviesDownloaded) / Double(stats.movieCount) : nil)
                }
                if settings[.lidarr].isConfigured {
                    StatTile(title: "Artists", value: "\(stats.artistCount)", caption: Format.bytes(stats.musicSize),
                             symbol: "music.mic", color: Theme.color(for: .lidarr))
                    StatTile(title: "Albums", value: "\(stats.albumCount)", caption: "\(stats.trackFiles) tracks on disk",
                             symbol: "square.stack", color: Theme.color(for: .lidarr))
                }
                StatTile(title: "Total", value: Format.bytes(stats.seriesSize + stats.movieSize + stats.musicSize),
                         caption: "TV, movies and music", symbol: "externaldrive", color: Theme.accent)
            }
            SectionHeader(title: "Recently added")
            if store.recentlyAdded.isEmpty {
                Text("Nothing yet.").foregroundStyle(Theme.secondaryText)
            }
            ForEach(store.recentlyAdded) { item in
                MediaRow(item: item, detail: Format.relative(item.date))
            }
        }
    }
}

struct MediaRow: View {
    let item: MediaItem
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.imageURL, symbol: item.service.symbol,
                    width: item.service == .lidarr ? 64 : 54, height: item.service == .lidarr ? 64 : 80)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.service.symbol)
                        .font(.caption2)
                        .foregroundStyle(Theme.color(for: item.service))
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if item.downloaded {
                        Pill(text: "On disk", color: Theme.good)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
