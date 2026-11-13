import Foundation
import Security
import UIKit

// MARK: Models

struct MediaItem: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let folder: String
    let kind: String
    let size: Int64
    let taken: Double?
    let width: Int?
    let height: Int?
    let duration: Double?
    var favorite: Bool

    var id: String { path }
    var isVideo: Bool { kind == "video" }
    var date: Date { Date(timeIntervalSince1970: taken ?? 0) }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Formats iOS can show full size without help from the server.
    var hasDisplayableOriginal: Bool {
        guard !isVideo else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"].contains(ext) && size < 60_000_000
    }

    /// Formats AVPlayer can stream.
    var isPlayable: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "3gp"].contains(ext)
    }
}

struct FolderEntry: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let count: Int
    let latest: Double?
    let cover: String?
    var id: String { path }
}

struct Listing: Codable {
    let path: String
    let name: String
    let folders: [FolderEntry]
    let items: [MediaItem]
}

struct TimelinePage: Codable {
    let items: [MediaItem]
    let offset: Int
    let done: Bool
}

struct ItemsResponse: Codable {
    let items: [MediaItem]
}

struct GalleryStatus: Codable {
    let images: Int
    let videos: Int
    let favorites: Int
    let scanning: Bool
    let lastScan: Double?
    let root: String
}

enum GalleryError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter your Reliquary server's address and token."
        case .unauthorized: return "The server refused the token. Check it matches GALLERY_TOKEN."
        case .server(let text): return text
        }
    }
}

// MARK: Client

struct GalleryClient {
    let base: URL
    let token: String

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024, directory: nil)
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init?(address: String, token: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !token.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text) else { return nil }
        base = url
        self.token = token
    }

    func url(_ path: String, _ query: [String: String] = [:], withToken: Bool = false) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if withToken { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items.isEmpty ? nil : items
        // "+" in a query is read as a space by many servers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func thumbURL(_ item: String, large: Bool = false) -> URL {
        url("thumb", ["path": item, "size": large ? "m" : "s"], withToken: true)
    }

    func fileURL(_ item: String) -> URL {
        url("file", ["path": item], withToken: true)
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var req = request(url(path, query))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await send(req)
        return try Self.decoder.decode(T.self, from: data)
    }

    func post(_ path: String, _ body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request(url(path), method: "POST", body: data))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await Self.session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw GalleryError.server("Couldn't reach the Reliquary server at \(base.absoluteString). Is Tailscale on and the server running?")
        }
        let (data, response) = result
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw GalleryError.unauthorized }
        guard (200..<300).contains(code) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw GalleryError.server("Server error: \(message ?? "HTTP \(code)")")
        }
        return data
    }

    /// Downloads an original to a temporary file named like the original, for sharing.
    func download(_ item: MediaItem) async throws -> URL {
        let (temp, response) = try await Self.session.download(for: request(url("file", ["path": item.path])))
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw GalleryError.server("Couldn't download \(item.name).")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.name)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}

// MARK: Images

/// Loads thumbnails once, decodes them off the main thread and keeps them in memory.
actor ImageLoader {
    static let shared = ImageLoader()

    // NSCache is thread-safe, so it can be read from outside the actor.
    nonisolated(unsafe) private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        memory.totalCostLimit = 200 * 1024 * 1024
    }

    nonisolated func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let result = try? await GalleryClient.session.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let data = result.0
            if let maxPixel {
                return Self.downsample(data, maxPixel: maxPixel)
            }
            return UIImage(data: data)?.preparingForDisplay()
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            memory.setObject(result, forKey: url as NSURL, cost: cost)
        }
        return result
    }

    /// Decodes a large original at a sensible size, honouring its orientation.
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func clear() {
        memory.removeAllObjects()
        GalleryClient.session.configuration.urlCache?.removeAllCachedResponses()
    }
}

// MARK: Keychain

enum Keychain {
    private static let service = "app.keepwatch.reliquary"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: Gothic dates

enum Roman {
    static func numeral(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var out = ""
        for (number, letters) in table {
            while remaining >= number {
                out += letters
                remaining -= number
            }
        }
        return out
    }

    /// "October · MMXIX"
    static func monthTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let month = date.formatted(.dateTime.month(.wide))
        return "\(month) · \(numeral(calendar.component(.year, from: date)))"
    }
}
