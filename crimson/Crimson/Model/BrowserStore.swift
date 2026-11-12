import SwiftUI

struct Bookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var date: Date
}

/// Holds the open tabs plus persisted bookmarks and history.
@MainActor
final class BrowserStore: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var currentID: UUID?
    @Published var bookmarks: [Bookmark] { didSet { persistBookmarks() } }
    @Published var history: [HistoryItem] { didSet { persistHistory() } }

    private let bookmarksKey = "bookmarks.v1"
    private let historyKey = "history.v1"

    init() {
        bookmarks = BrowserStore.decode(bookmarksKey) ?? [
            Bookmark(title: "DuckDuckGo", url: "https://duckduckgo.com"),
        ]
        history = BrowserStore.decode(historyKey) ?? []
        // First tab is created in BrowserView once the ad-block rule list has compiled.
    }

    var current: BrowserTab? { tabs.first { $0.id == currentID } }

    func newTab(_ url: String? = nil, isPrivate: Bool = false, activate: Bool = true) {
        let tab = BrowserTab(isPrivate: isPrivate, store: self)
        tabs.append(tab)
        if activate { currentID = tab.id }
        tab.load(url ?? "https://duckduckgo.com")
    }

    func select(_ tab: BrowserTab) { currentID = tab.id }

    func close(_ tab: BrowserTab) {
        let wasCurrent = currentID == tab.id
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { newTab() }
        else if wasCurrent { currentID = tabs.last?.id }
    }

    func closeAll() {
        tabs.removeAll()
        newTab()
    }

    // MARK: bookmarks

    func isBookmarked(_ url: String) -> Bool { bookmarks.contains { $0.url == url } }

    func toggleBookmark(title: String, url: String) {
        if let i = bookmarks.firstIndex(where: { $0.url == url }) { bookmarks.remove(at: i) }
        else if !url.isEmpty { bookmarks.insert(Bookmark(title: title, url: url), at: 0) }
    }

    func removeBookmark(_ b: Bookmark) { bookmarks.removeAll { $0.id == b.id } }

    // MARK: history

    func recordHistory(title: String, url: String) {
        history.removeAll { $0.url == url }
        history.insert(HistoryItem(title: title, url: url, date: Date()), at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
    }

    func clearHistory() { history = [] }

    // MARK: persistence

    private func persistBookmarks() { BrowserStore.encode(bookmarks, bookmarksKey) }
    private func persistHistory() { BrowserStore.encode(history, historyKey) }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
    }
}
