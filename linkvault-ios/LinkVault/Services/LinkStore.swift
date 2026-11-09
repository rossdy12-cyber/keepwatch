import Foundation
import Combine

@MainActor
final class LinkStore: ObservableObject {
    static let appGroupID = "group.uk.co.rossdymond.linkvault"
    @Published private(set) var links: [LinkItem] = []
    @Published private(set) var storageError: String?
    private let storeURL: URL
    private var canSave = true

    init() {
        storeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("linkvault-links.json")
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            links = try decoder.decode([LinkItem].self, from: Data(contentsOf: storeURL))
        } catch {
            canSave = false
            storageError = "Saved links could not be loaded. The original file has been preserved. \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persist(_ candidate: [LinkItem]) -> Bool {
        guard canSave else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(candidate).write(to: storeURL, options: .atomic)
            links = candidate
            storageError = nil
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    static func webURL(_ raw: String) -> URL? {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        return c.url
    }

    func normalizedURL(_ raw: String) -> String {
        guard let url = Self.webURL(raw), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return raw }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.fragment = nil
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
        return c.string ?? raw
    }

    func containsNormalizedURL(_ raw: String) -> Bool {
        guard Self.webURL(raw) != nil else { return false }
        return links.contains { normalizedURL($0.url) == normalizedURL(raw) }
    }

    @discardableResult
    func add(_ link: LinkItem) -> Bool {
        guard Self.webURL(link.url) != nil, !containsNormalizedURL(link.url) else { return false }
        return persist([link] + links)
    }

    func update(_ link: LinkItem) {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        var candidate = links
        candidate[index] = link
        persist(candidate)
    }

    func delete(_ link: LinkItem) { persist(links.filter { $0.id != link.id }) }
    func toggleFavourite(_ link: LinkItem) {
        guard var current = links.first(where: { $0.id == link.id }) else { return }
        current.isFavourite.toggle()
        update(current)
    }
    func toggleArchive(_ link: LinkItem) {
        guard var current = links.first(where: { $0.id == link.id }) else { return }
        current.isArchived.toggle()
        update(current)
    }
    func markRead(_ link: LinkItem, isRead: Bool) {
        guard var current = links.first(where: { $0.id == link.id }) else { return }
        current.isRead = isRead
        current.readAt = isRead ? Date() : nil
        update(current)
    }
    func allTags() -> [String] {
        Array(Set(links.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func importPendingSharedURLs() {
        guard canSave, let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }
        let inbox = directory.appendingPathComponent("PendingLinks", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            do {
                let raw = try JSONDecoder().decode(String.self, from: Data(contentsOf: file))
                guard let url = Self.webURL(raw) else { continue }
                if containsNormalizedURL(raw) || add(LinkItem(url: url.absoluteString)) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch { storageError = error.localizedDescription }
        }
    }
}
