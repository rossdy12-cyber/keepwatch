import Foundation
import LocalAuthentication
import SwiftUI

struct StashStats: Equatable {
    var sceneCount: Int = 0
    var imageCount: Int = 0
    var galleryCount: Int = 0
    var performerCount: Int = 0
    var studioCount: Int = 0
    var tagCount: Int = 0
}

struct StashSceneItem: Identifiable, Equatable {
    var id: String
    var title: String
    var details: String
    var duration: Double
    var width: Int
    var height: Int
    var screenshotURL: URL?
    var streamURL: URL?
    var studioName: String?
    var rating100: Int?
}

struct StashImageItem: Identifiable, Equatable {
    var id: String
    var title: String
    var width: Int
    var height: Int
    var thumbnailURL: URL?
    var imageURL: URL?
}

enum StashSection: String, CaseIterable, Identifiable {
    case home = ""
    case scenes = "scenes"
    case images = "images"
    case galleries = "galleries"
    case performers = "performers"
    case studios = "studios"
    case tags = "tags"
    case markers = "scenes/markers"
    case settings = "settings"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .scenes: return "Scenes"
        case .images: return "Images"
        case .galleries: return "Galleries"
        case .performers: return "Performers"
        case .studios: return "Studios"
        case .tags: return "Tags"
        case .markers: return "Markers"
        case .settings: return "Server Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .scenes: return "film.stack.fill"
        case .images: return "photo.on.rectangle.angled"
        case .galleries: return "rectangle.stack.fill"
        case .performers: return "person.2.fill"
        case .studios: return "building.2.fill"
        case .tags: return "tag.fill"
        case .markers: return "bookmark.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
final class StashStore: ObservableObject {
    private static let serverAddressKey = "stash.serverAddress"
    private static let apiKeyKey = "stash.apiKey"
    private static let biometricLockKey = "stash.biometricLock"
    private static let privacyBlurKey = "stash.privacyBlur"
    private static let acceptSelfSignedKey = "stash.acceptSelfSigned"

    static let presets: [(name: String, url: String, subtitle: String)] = [
        ("TrueNAS Tailscale", "http://100.85.127.42:9999", "Recommended over Tailscale VPN"),
        ("TrueNAS Direct", "http://100.85.127.42:9999", "Direct TrueNAS IP on port 9999")
    ]

    @Published var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.serverAddressKey) }
    }

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey) }
    }

    @Published var biometricLock: Bool {
        didSet { UserDefaults.standard.set(biometricLock, forKey: Self.biometricLockKey) }
    }

    @Published var privacyBlur: Bool {
        didSet { UserDefaults.standard.set(privacyBlur, forKey: Self.privacyBlurKey) }
    }

    @Published var acceptSelfSigned: Bool {
        didSet {
            UserDefaults.standard.set(acceptSelfSigned, forKey: Self.acceptSelfSignedKey)
            StashCertPolicy.acceptSelfSigned = acceptSelfSigned
        }
    }

    @Published var isUnlocked: Bool = true
    @Published var isOnline: Bool = false
    @Published var statusText: String = "Checking connection…"
    @Published var stats = StashStats()
    @Published var scenes: [StashSceneItem] = []
    @Published var images: [StashImageItem] = []
    @Published var isLoadingMedia: Bool = false
    @Published var activeSection: StashSection = .home

    init() {
        let defaults = UserDefaults.standard
        let savedAddress = defaults.string(forKey: Self.serverAddressKey) ?? "http://100.85.127.42:9999"
        serverAddress = savedAddress
        apiKey = defaults.string(forKey: Self.apiKeyKey) ?? ""
        let lockEnabled = defaults.object(forKey: Self.biometricLockKey) as? Bool ?? false
        biometricLock = lockEnabled
        privacyBlur = defaults.object(forKey: Self.privacyBlurKey) as? Bool ?? true
        let selfSigned = defaults.object(forKey: Self.acceptSelfSignedKey) as? Bool ?? true
        acceptSelfSigned = selfSigned
        StashCertPolicy.acceptSelfSigned = selfSigned
        isUnlocked = !lockEnabled
    }

    var baseURL: URL? {
        var text = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    func url(for section: StashSection) -> URL? {
        guard let base = baseURL else { return nil }
        if section.rawValue.isEmpty { return base }
        return URL(string: base.absoluteString + "/" + section.rawValue)
    }

    func unlockWithBiometrics() {
        guard biometricLock else {
            isUnlocked = true
            return
        }
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Stash") { success, _ in
                Task { @MainActor in
                    if success { self.isUnlocked = true }
                }
            }
        } else {
            isUnlocked = true
        }
    }

    func lockIfNeeded() {
        if biometricLock {
            isUnlocked = false
        }
    }

    // MARK: - GraphQL API

    private func makeGraphQLRequest(query: String, variables: [String: Any] = [:]) -> URLRequest? {
        guard let base = baseURL, let url = URL(string: base.absoluteString + "/graphql") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            req.setValue(trimmedKey, forHTTPHeaderField: "ApiKey")
        }
        let body: [String: Any] = ["query": query, "variables": variables]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func withApiKey(_ urlString: String?) -> URL? {
        guard let raw = urlString, !raw.isEmpty, var comps = URLComponents(string: raw) else { return nil }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            var items = comps.queryItems ?? []
            if !items.contains(where: { $0.name == "apikey" }) {
                items.append(URLQueryItem(name: "apikey", value: trimmedKey))
                comps.queryItems = items
            }
        }
        return comps.url
    }

    func refreshAll(searchQuery: String = "") async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        await fetchStats()
        await fetchScenes(search: searchQuery)
        await fetchImages(search: searchQuery)
    }

    func fetchStats() async {
        let query = """
        query {
          stats {
            scene_count
            image_count
            gallery_count
            performer_count
            studio_count
            tag_count
          }
        }
        """
        guard let req = makeGraphQLRequest(query: query) else {
            isOnline = false
            statusText = "Invalid server address"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                isOnline = false
                statusText = "Server returned an error"
                return
            }
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataDict = root["data"] as? [String: Any],
               let s = dataDict["stats"] as? [String: Any] {
                stats = StashStats(
                    sceneCount: s["scene_count"] as? Int ?? 0,
                    imageCount: s["image_count"] as? Int ?? 0,
                    galleryCount: s["gallery_count"] as? Int ?? 0,
                    performerCount: s["performer_count"] as? Int ?? 0,
                    studioCount: s["studio_count"] as? Int ?? 0,
                    tagCount: s["tag_count"] as? Int ?? 0
                )
                isOnline = true
                statusText = "Connected (\(stats.sceneCount) scenes · \(stats.imageCount) images)"
            }
        } catch {
            isOnline = false
            statusText = "Offline — check Tailscale or server URL"
        }
    }

    func fetchScenes(search: String = "") async {
        let query = """
        query FindScenes($q: String!) {
          findScenes(filter: { q: $q, per_page: 60, sort: "created_at", direction: DESC }) {
            scenes {
              id
              title
              details
              rating100
              studio { name }
              files {
                path
                duration
                width
                height
              }
              paths {
                screenshot
                stream
              }
            }
          }
        }
        """
        guard let req = makeGraphQLRequest(query: query, variables: ["q": search]) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = root["data"] as? [String: Any],
                  let findScenes = dataDict["findScenes"] as? [String: Any],
                  let rawScenes = findScenes["scenes"] as? [[String: Any]] else { return }

            var parsed: [StashSceneItem] = []
            for item in rawScenes {
                let id = String(describing: item["id"] ?? "")
                let files = item["files"] as? [[String: Any]] ?? []
                let firstFile = files.first ?? [:]
                let filePath = firstFile["path"] as? String ?? ""
                let fallbackTitle = (filePath as NSString).lastPathComponent
                let rawTitle = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? (fallbackTitle.isEmpty ? "Scene #\(id)" : fallbackTitle) : rawTitle
                let details = item["details"] as? String ?? ""
                let duration = firstFile["duration"] as? Double ?? 0
                let width = firstFile["width"] as? Int ?? 0
                let height = firstFile["height"] as? Int ?? 0
                let paths = item["paths"] as? [String: Any] ?? [:]
                let studio = (item["studio"] as? [String: Any])?["name"] as? String
                let rating100 = item["rating100"] as? Int

                parsed.append(StashSceneItem(
                    id: id,
                    title: title,
                    details: details,
                    duration: duration,
                    width: width,
                    height: height,
                    screenshotURL: withApiKey(paths["screenshot"] as? String),
                    streamURL: withApiKey(paths["stream"] as? String),
                    studioName: studio,
                    rating100: rating100
                ))
            }
            scenes = parsed
        } catch {
            // Keep existing scenes on transient error
        }
    }

    func fetchImages(search: String = "") async {
        let query = """
        query FindImages($q: String!) {
          findImages(filter: { q: $q, per_page: 80, sort: "created_at", direction: DESC }) {
            images {
              id
              title
              visual_files {
                ... on ImageFile {
                  path
                  width
                  height
                }
                ... on VideoFile {
                  path
                  width
                  height
                }
              }
              paths {
                thumbnail
                image
              }
            }
          }
        }
        """
        guard let req = makeGraphQLRequest(query: query, variables: ["q": search]) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = root["data"] as? [String: Any],
                  let findImages = dataDict["findImages"] as? [String: Any],
                  let rawImages = findImages["images"] as? [[String: Any]] else { return }

            var parsed: [StashImageItem] = []
            for item in rawImages {
                let id = String(describing: item["id"] ?? "")
                let files = item["visual_files"] as? [[String: Any]] ?? []
                let firstFile = files.first ?? [:]
                let filePath = firstFile["path"] as? String ?? ""
                let fallbackTitle = (filePath as NSString).lastPathComponent
                let rawTitle = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? (fallbackTitle.isEmpty ? "Image #\(id)" : fallbackTitle) : rawTitle
                let width = firstFile["width"] as? Int ?? 0
                let height = firstFile["height"] as? Int ?? 0
                let paths = item["paths"] as? [String: Any] ?? [:]

                parsed.append(StashImageItem(
                    id: id,
                    title: title,
                    width: width,
                    height: height,
                    thumbnailURL: withApiKey(paths["thumbnail"] as? String),
                    imageURL: withApiKey(paths["image"] as? String)
                ))
            }
            images = parsed
        } catch {
            // Keep existing images on transient error
        }
    }

    func triggerScan() async -> String {
        let query = """
        mutation {
          metadataScan(input: { scanGenerateCovers: true, scanGeneratePreviews: true, scanGenerateThumbnails: true })
        }
        """
        guard let req = makeGraphQLRequest(query: query) else { return "Invalid server URL" }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return "Started scanning /data/IDrive-Sync"
            }
            return "Scan request failed"
        } catch {
            return "Couldn't reach Stash server"
        }
    }

    func triggerGenerate() async -> String {
        let query = """
        mutation {
          metadataGenerate(input: { covers: true, previews: true, sprites: true, markers: true, transcodes: false })
        }
        """
        guard let req = makeGraphQLRequest(query: query) else { return "Invalid server URL" }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return "Started generating thumbnails & previews"
            }
            return "Generate request failed"
        } catch {
            return "Couldn't reach Stash server"
        }
    }
}

enum StashCertPolicy {
    static var acceptSelfSigned = true
}

enum StashTheme {
    static let background = Color(red: 0.05, green: 0.07, blue: 0.11)
    static let card = Color(red: 0.10, green: 0.13, blue: 0.20)
    static let border = Color.white.opacity(0.09)
    static let accent = Color(red: 0.18, green: 0.72, blue: 0.96)
    static let textPrimary = Color(red: 0.95, green: 0.97, blue: 1.0)
    static let textSecondary = Color(red: 0.60, green: 0.67, blue: 0.78)
    static let success = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let warning = Color(red: 0.98, green: 0.65, blue: 0.20)
}
