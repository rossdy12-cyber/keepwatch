import Foundation

struct MediaItem: Identifiable {
    var id: String
    var service: Service
    var title: String
    var subtitle: String
    var date: Date?
    var imageURL: URL?
    var downloaded: Bool
}

struct LibraryStats {
    var seriesCount = 0
    var episodeFiles = 0
    var episodesTotal = 0
    var seriesSize = 0.0
    var movieCount = 0
    var moviesDownloaded = 0
    var movieSize = 0.0
    var artistCount = 0
    var albumCount = 0
    var trackFiles = 0
    var musicSize = 0.0
}

/// Sonarr, Radarr and Lidarr: what's coming up, what's missing and what's in the library.
@MainActor
final class MediaStore: ObservableObject {
    @Published var upcoming: [MediaItem] = []
    @Published var missing: [Service: [MediaItem]] = [:]
    @Published var missingTotals: [Service: Int] = [:]
    @Published var stats = LibraryStats()
    @Published var recentlyAdded: [MediaItem] = []
    @Published var errors: [Service: String] = [:]
    @Published var loading = false
    @Published var loadedOnce = false

    static let services: [Service] = [.sonarr, .radarr, .lidarr]
    nonisolated static let upcomingDays = 14

    func refresh(_ settings: ServiceSettings) async {
        loading = true
        defer {
            loading = false
            loadedOnce = true
        }
        var newErrors: [Service: String] = [:]
        var newUpcoming: [MediaItem] = []
        var newRecent: [MediaItem] = []
        var newStats = LibraryStats()

        let clients: [(Service, ArrClient?)] = Self.services.map { service in
            (service, try? ArrClient(service: service, config: settings[service]))
        }

        await withTaskGroup(of: (Service, Result<ServiceSnapshot, Error>).self) { group in
            for (service, client) in clients {
                guard let client else { continue }
                group.addTask {
                    do {
                        return (service, .success(try await Self.load(client)))
                    } catch {
                        return (service, .failure(error))
                    }
                }
            }
            for await (service, result) in group {
                switch result {
                case .success(let snapshot):
                    newUpcoming += snapshot.upcoming
                    newRecent += snapshot.recent
                    missing[service] = snapshot.missing
                    missingTotals[service] = snapshot.missingTotal
                    snapshot.addStats(&newStats)
                case .failure(let error):
                    if !isCancellation(error) { newErrors[service] = describe(error) }
                }
            }
        }

        for (service, client) in clients where client == nil {
            missing[service] = nil
            missingTotals[service] = nil
        }
        upcoming = newUpcoming.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        recentlyAdded = Array(newRecent.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(20))
        stats = newStats
        errors = newErrors
    }

    // MARK: - Loading one service

    struct ServiceSnapshot {
        var upcoming: [MediaItem] = []
        var missing: [MediaItem] = []
        var missingTotal = 0
        var recent: [MediaItem] = []
        var stats = LibraryStats()

        func addStats(_ total: inout LibraryStats) {
            total.seriesCount += stats.seriesCount
            total.episodeFiles += stats.episodeFiles
            total.episodesTotal += stats.episodesTotal
            total.seriesSize += stats.seriesSize
            total.movieCount += stats.movieCount
            total.moviesDownloaded += stats.moviesDownloaded
            total.movieSize += stats.movieSize
            total.artistCount += stats.artistCount
            total.albumCount += stats.albumCount
            total.trackFiles += stats.trackFiles
            total.musicSize += stats.musicSize
        }
    }

    nonisolated private static func window() -> [String: String] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: upcomingDays, to: start) ?? start
        return ["start": DateParsing.isoString(start), "end": DateParsing.isoString(end)]
    }

    nonisolated private static func load(_ client: ArrClient) async throws -> ServiceSnapshot {
        switch client.service {
        case .sonarr: return try await loadSonarr(client)
        case .radarr: return try await loadRadarr(client)
        default: return try await loadLidarr(client)
        }
    }

    nonisolated private static func episodeItem(_ episode: JSONValue, client: ArrClient) -> MediaItem {
        let series = episode["series"]
        let code = Format.episodeCode(season: episode["seasonNumber"].int, episode: episode["episodeNumber"].int)
        return MediaItem(
            id: "sonarr-ep-\(episode["id"].int ?? 0)",
            service: .sonarr,
            title: series["title"].string ?? "Unknown series",
            subtitle: [code, episode["title"].string ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
            date: episode["airDateUtc"].date,
            imageURL: client.imageURL(series["images"], prefer: ["poster"]),
            downloaded: episode["hasFile"].bool ?? false
        )
    }

    nonisolated private static func loadSonarr(_ client: ArrClient) async throws -> ServiceSnapshot {
        var query = window()
        query["includeSeries"] = "true"
        async let calendar = client.get("/calendar", query)
        async let wanted = client.get("/wanted/missing", ["page": "1", "pageSize": "50", "includeSeries": "true", "monitored": "true"])
        async let seriesList = client.get("/series")

        var snapshot = ServiceSnapshot()
        snapshot.upcoming = try await calendar.array.map { episodeItem($0, client: client) }
        let wantedValue = try await wanted
        snapshot.missing = wantedValue["records"].array.map { episodeItem($0, client: client) }
        snapshot.missingTotal = wantedValue["totalRecords"].int ?? snapshot.missing.count

        let series = try await seriesList.array
        snapshot.stats.seriesCount = series.count
        for show in series {
            let statistics = show["statistics"]
            snapshot.stats.episodeFiles += statistics["episodeFileCount"].int ?? 0
            snapshot.stats.episodesTotal += statistics["episodeCount"].int ?? 0
            snapshot.stats.seriesSize += statistics["sizeOnDisk"].double ?? 0
        }
        snapshot.recent = series
            .sorted { ($0["added"].date ?? .distantPast) > ($1["added"].date ?? .distantPast) }
            .prefix(10)
            .map { show in
                MediaItem(
                    id: "sonarr-series-\(show["id"].int ?? 0)",
                    service: .sonarr,
                    title: show["title"].string ?? "Unknown",
                    subtitle: "\(show["statistics"]["episodeFileCount"].int ?? 0) episodes · \(Format.bytes(show["statistics"]["sizeOnDisk"].double))",
                    date: show["added"].date,
                    imageURL: client.imageURL(show["images"], prefer: ["poster"]),
                    downloaded: true
                )
            }
        return snapshot
    }

    nonisolated private static func movieItem(_ movie: JSONValue, client: ArrClient, date: Date?, idPrefix: String) -> MediaItem {
        let year = movie["year"].int.map(String.init) ?? ""
        let studio = movie["studio"].string ?? ""
        return MediaItem(
            id: "\(idPrefix)-\(movie["id"].int ?? 0)",
            service: .radarr,
            title: movie["title"].string ?? "Unknown",
            subtitle: [year, studio].filter { !$0.isEmpty }.joined(separator: " · "),
            date: date,
            imageURL: client.imageURL(movie["images"], prefer: ["poster"]),
            downloaded: movie["hasFile"].bool ?? false
        )
    }

    nonisolated private static func loadRadarr(_ client: ArrClient) async throws -> ServiceSnapshot {
        let query = window()
        async let calendar = client.get("/calendar", query)
        async let movieList = client.get("/movie")

        let start = DateParsing.iso(query["start"] ?? "") ?? Date()
        var snapshot = ServiceSnapshot()
        snapshot.upcoming = try await calendar.array.map { movie in
            let dates = ["inCinemas", "digitalRelease", "physicalRelease"].compactMap { movie[$0].date }
            let next = dates.filter { $0 >= start }.min() ?? dates.max()
            return movieItem(movie, client: client, date: next, idPrefix: "radarr-cal")
        }

        let movies = try await movieList.array
        snapshot.stats.movieCount = movies.count
        for movie in movies {
            if movie["hasFile"].bool == true { snapshot.stats.moviesDownloaded += 1 }
            snapshot.stats.movieSize += movie["sizeOnDisk"].double ?? movie["statistics"]["sizeOnDisk"].double ?? 0
        }
        let missingMovies = movies.filter {
            $0["monitored"].bool == true && $0["hasFile"].bool != true && $0["isAvailable"].bool == true
        }
        snapshot.missingTotal = missingMovies.count
        snapshot.missing = missingMovies
            .sorted { ($0["title"].string ?? "") < ($1["title"].string ?? "") }
            .prefix(100)
            .map { movieItem($0, client: client, date: $0["digitalRelease"].date ?? $0["inCinemas"].date, idPrefix: "radarr-missing") }
        snapshot.recent = movies
            .filter { $0["hasFile"].bool == true }
            .sorted { ($0["movieFile"]["dateAdded"].date ?? $0["added"].date ?? .distantPast) > ($1["movieFile"]["dateAdded"].date ?? $1["added"].date ?? .distantPast) }
            .prefix(10)
            .map { movieItem($0, client: client, date: $0["movieFile"]["dateAdded"].date ?? $0["added"].date, idPrefix: "radarr-recent") }
        return snapshot
    }

    nonisolated private static func albumItem(_ album: JSONValue, client: ArrClient, idPrefix: String) -> MediaItem {
        let artist = album["artist"]["artistName"].string ?? ""
        let type = album["albumType"].string ?? ""
        let image = client.imageURL(album["images"], prefer: ["cover"]) ?? client.imageURL(album["artist"]["images"], prefer: ["poster"])
        return MediaItem(
            id: "\(idPrefix)-\(album["id"].int ?? 0)",
            service: .lidarr,
            title: album["title"].string ?? "Unknown album",
            subtitle: [artist, type].filter { !$0.isEmpty }.joined(separator: " · "),
            date: album["releaseDate"].date,
            imageURL: image,
            downloaded: (album["statistics"]["trackFileCount"].int ?? 0) > 0
        )
    }

    nonisolated private static func loadLidarr(_ client: ArrClient) async throws -> ServiceSnapshot {
        var query = window()
        query["includeArtist"] = "true"
        async let calendar = client.get("/calendar", query)
        async let wanted = client.get("/wanted/missing", ["page": "1", "pageSize": "50", "includeArtist": "true", "monitored": "true"])
        async let artistList = client.get("/artist")

        var snapshot = ServiceSnapshot()
        snapshot.upcoming = try await calendar.array.map { albumItem($0, client: client, idPrefix: "lidarr-cal") }
        let wantedValue = try await wanted
        snapshot.missing = wantedValue["records"].array.map { albumItem($0, client: client, idPrefix: "lidarr-missing") }
        snapshot.missingTotal = wantedValue["totalRecords"].int ?? snapshot.missing.count

        let artists = try await artistList.array
        snapshot.stats.artistCount = artists.count
        for artist in artists {
            let statistics = artist["statistics"]
            snapshot.stats.albumCount += statistics["albumCount"].int ?? 0
            snapshot.stats.trackFiles += statistics["trackFileCount"].int ?? 0
            snapshot.stats.musicSize += statistics["sizeOnDisk"].double ?? 0
        }
        snapshot.recent = artists
            .sorted { ($0["added"].date ?? .distantPast) > ($1["added"].date ?? .distantPast) }
            .prefix(10)
            .map { artist in
                MediaItem(
                    id: "lidarr-artist-\(artist["id"].int ?? 0)",
                    service: .lidarr,
                    title: artist["artistName"].string ?? "Unknown",
                    subtitle: "\(artist["statistics"]["albumCount"].int ?? 0) albums · \(Format.bytes(artist["statistics"]["sizeOnDisk"].double))",
                    date: artist["added"].date,
                    imageURL: client.imageURL(artist["images"], prefer: ["poster"]),
                    downloaded: true
                )
            }
        return snapshot
    }
}
