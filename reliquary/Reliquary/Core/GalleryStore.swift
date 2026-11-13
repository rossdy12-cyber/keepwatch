import Foundation
import SwiftUI

enum KindFilter: String, CaseIterable, Identifiable {
    case all, image, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Everything"
        case .image: return "Photos"
        case .video: return "Videos"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.3x3"
        case .image: return "photo"
        case .video: return "film"
        }
    }
}

struct MonthSection: Identifiable {
    let id: String
    let title: String
    let items: [MediaItem]
}

@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var client: GalleryClient?
    @Published private(set) var address: String
    @Published private(set) var status: GalleryStatus?

    @Published private(set) var timeline: [MediaItem] = []
    @Published private(set) var timelineDone = false
    @Published private(set) var loadingTimeline = false
    @Published var filter: KindFilter = .all {
        didSet { if filter != oldValue { Task { await reloadTimeline() } } }
    }

    @Published private(set) var favorites: [MediaItem] = []
    @Published private(set) var searchResults: [MediaItem]?
    @Published private(set) var searching = false
    @Published var errorMessage: String?

    /// Favourite changes made on this phone, applied on top of whatever a list says.
    @Published private(set) var favoriteOverrides: [String: Bool] = [:]

    private var timelineToken = UUID()

    init() {
        address = UserDefaults.standard.string(forKey: "reliquary.address") ?? ""
        client = GalleryClient(address: address, token: Keychain.read(account: "token") ?? "")
    }

    var isConfigured: Bool { client != nil }

    // MARK: Setup

    func connect(address: String, token: String) async throws {
        guard let candidate = GalleryClient(address: address, token: token) else { throw GalleryError.notConfigured }
        let checked: GalleryStatus = try await candidate.get("api/status")
        UserDefaults.standard.set(address, forKey: "reliquary.address")
        Keychain.save(token, account: "token")
        self.address = address
        client = candidate
        status = checked
        await reloadTimeline()
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: "reliquary.address")
        Keychain.save("", account: "token")
        client = nil
        address = ""
        timeline = []
        favorites = []
        status = nil
        favoriteOverrides = [:]
    }

    // MARK: Loading

    func refreshStatus() async {
        guard let client else { return }
        if let fresh: GalleryStatus = try? await client.get("api/status") {
            status = fresh
        }
    }

    func reloadTimeline() async {
        guard let client else { return }
        let token = UUID()
        timelineToken = token
        loadingTimeline = true
        defer { if timelineToken == token { loadingTimeline = false } }
        do {
            let page: TimelinePage = try await client.get("api/timeline", query(offset: 0))
            guard timelineToken == token else { return }
            timeline = page.items
            timelineDone = page.done
            errorMessage = nil
        } catch {
            if timelineToken == token { report(error) }
        }
        await refreshStatus()
    }

    func loadMoreTimeline() async {
        guard let client, !timelineDone, !loadingTimeline else { return }
        let token = timelineToken
        loadingTimeline = true
        defer { loadingTimeline = false }
        do {
            let page: TimelinePage = try await client.get("api/timeline", query(offset: timeline.count))
            guard timelineToken == token else { return }
            let known = Set(timeline.map(\.path))
            timeline += page.items.filter { !known.contains($0.path) }
            timelineDone = page.done
        } catch {
            report(error)
        }
    }

    private func query(offset: Int) -> [String: String] {
        var query = ["offset": String(offset), "limit": "300"]
        if filter != .all { query["kind"] = filter.rawValue }
        return query
    }

    func loadFavorites() async {
        guard let client else { return }
        do {
            let response: ItemsResponse = try await client.get("api/favorites")
            favorites = response.items
        } catch {
            report(error)
        }
    }

    func listing(_ path: String) async throws -> Listing {
        guard let client else { throw GalleryError.notConfigured }
        return try await client.get("api/list", ["path": path])
    }

    func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let client, !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        searching = true
        defer { searching = false }
        do {
            let response: ItemsResponse = try await client.get("api/search", ["q": trimmed])
            searchResults = response.items
        } catch {
            report(error)
        }
    }

    func clearSearch() { searchResults = nil }

    func rescan() async {
        guard let client else { return }
        do {
            try await client.post("api/rescan", [:])
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshStatus()
        } catch {
            report(error)
        }
    }

    // MARK: Favourites

    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteOverrides[item.path] ?? item.favorite
    }

    func toggleFavorite(_ item: MediaItem) async {
        guard let client else { return }
        let newValue = !isFavorite(item)
        favoriteOverrides[item.path] = newValue
        if newValue {
            if !favorites.contains(where: { $0.path == item.path }) {
                var copy = item
                copy.favorite = true
                favorites.insert(copy, at: 0)
            }
        } else {
            favorites.removeAll { $0.path == item.path }
        }
        do {
            try await client.post("api/favorite", ["path": item.path, "favorite": newValue])
        } catch {
            favoriteOverrides[item.path] = !newValue
            report(error)
        }
    }

    // MARK: Helpers

    static func sections(_ items: [MediaItem]) -> [MonthSection] {
        var result: [MonthSection] = []
        var currentKey = ""
        var bucket: [MediaItem] = []
        let calendar = Calendar.current
        for item in items {
            let parts = calendar.dateComponents([.year, .month], from: item.date)
            let key = "\(parts.year ?? 0)-\(parts.month ?? 0)"
            if key != currentKey, !bucket.isEmpty {
                result.append(MonthSection(id: currentKey, title: Roman.monthTitle(bucket[0].date), items: bucket))
                bucket = []
            }
            currentKey = key
            bucket.append(item)
        }
        if !bucket.isEmpty {
            result.append(MonthSection(id: currentKey, title: Roman.monthTitle(bucket[0].date), items: bucket))
        }
        return result
    }

    func report(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        errorMessage = error.localizedDescription
    }
}
