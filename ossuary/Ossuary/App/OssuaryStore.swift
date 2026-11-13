import Foundation
import Security
import SwiftUI
import UIKit

struct GameSystem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let retrodeck: Bool
    let count: Int
    let cover: String?
}

struct Game: Codable, Identifiable, Hashable {
    let path: String
    let file: String
    let title: String
    let system: String
    let folder: Bool
    let size: Int64
    let added: Double
    let retrodeck: Bool
    var id: String { path }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

private struct SystemsResponse: Codable { let systems: [GameSystem] }
private struct GamesResponse: Codable { let games: [Game] }

/// A finished download in the app's Documents folder (visible in the Files app).
struct LocalGame: Identifiable, Hashable {
    let url: URL
    let system: String
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum OssuaryError: LocalizedError {
    case notConfigured, unauthorized, server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter your Ossuary server's address and token."
        case .unauthorized: return "The server refused the token. Check it matches OSSUARY_TOKEN."
        case .server(let text): return text
        }
    }
}

@MainActor
final class OssuaryStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var address: String
    @Published private(set) var token: String
    @Published private(set) var systems: [GameSystem] = []
    @Published private(set) var recent: [Game] = []
    @Published private(set) var local: [LocalGame] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published var errorMessage: String?

    private var api = URLSession(configuration: .default)
    private lazy var downloads = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var tasks: [Int: Game] = [:]

    override init() {
        address = UserDefaults.standard.string(forKey: "ossuary.address") ?? ""
        token = Keychain.read("token") ?? ""
        super.init()
        scanLocal()
    }

    var isConfigured: Bool { base != nil && !token.isEmpty }

    private var base: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    func url(_ path: String, _ query: [String: String] = [:], token withToken: Bool = false) -> URL? {
        guard let base, var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if withToken { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items.isEmpty ? nil : items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    func artURL(_ game: Game) -> URL? { url("art", ["path": game.path], token: true) }
    func artURL(path: String) -> URL? { url("art", ["path": path], token: true) }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard let target = url(path, query) else { throw OssuaryError.notConfigured }
        var request = URLRequest(url: target)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let result: (Data, URLResponse)
        do {
            result = try await api.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw OssuaryError.server("Couldn't reach the Ossuary server at \(address). Is Tailscale on and the server running?")
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw OssuaryError.unauthorized }
        guard (200..<300).contains(code) else { throw OssuaryError.server("Server error (HTTP \(code)).") }
        return try JSONDecoder().decode(T.self, from: result.0)
    }

    // MARK: Setup

    func connect(address: String, token: String) async throws {
        let oldAddress = self.address, oldToken = self.token
        self.address = address
        self.token = token
        do {
            let response: SystemsResponse = try await get("api/systems")
            systems = response.systems
            UserDefaults.standard.set(address, forKey: "ossuary.address")
            Keychain.save(token, account: "token")
            await loadRecent()
        } catch {
            self.address = oldAddress
            self.token = oldToken
            throw error
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: "ossuary.address")
        Keychain.save("", account: "token")
        address = ""
        token = ""
        systems = []
        recent = []
    }

    // MARK: Library

    func loadSystems() async {
        do {
            let response: SystemsResponse = try await get("api/systems")
            systems = response.systems
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadRecent() async {
        if let response: GamesResponse = try? await get("api/recent") { recent = response.games }
    }

    func games(in system: String) async throws -> [Game] {
        let response: GamesResponse = try await get("api/games", ["system": system])
        return response.games
    }

    func search(_ text: String) async -> [Game] {
        let response: GamesResponse? = try? await get("api/search", ["q": text])
        return response?.games ?? []
    }

    // MARK: Downloads

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func localURL(for game: Game) -> URL {
        Self.documents.appendingPathComponent(game.system, isDirectory: true).appendingPathComponent(game.file)
    }

    func isDownloaded(_ game: Game) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: game).path)
    }

    func download(_ game: Game) {
        guard !game.folder, progress[game.path] == nil, let target = url("file", ["path": game.path]) else { return }
        var request = URLRequest(url: target)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = downloads.downloadTask(with: request)
        tasks[task.taskIdentifier] = game
        progress[game.path] = 0
        task.resume()
    }

    func cancel(_ game: Game) {
        downloads.getAllTasks { [weak self] all in
            Task { @MainActor in
                guard let self else { return }
                for task in all where self.tasks[task.taskIdentifier]?.path == game.path {
                    task.cancel()
                }
                self.progress[game.path] = nil
            }
        }
    }

    func delete(_ item: LocalGame) {
        try? FileManager.default.removeItem(at: item.url)
        scanLocal()
    }

    func scanLocal() {
        var found: [LocalGame] = []
        let fm = FileManager.default
        if let systems = try? fm.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: nil) {
            for folder in systems where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                    found.append(LocalGame(url: file, system: folder.lastPathComponent, size: Int64(size)))
                }
            }
        }
        local = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        MainActor.assumeIsolated {
            if let game = tasks[id] { progress[game.path] = fraction }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // The temporary file disappears when this returns, so move it now.
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: holding)
        MainActor.assumeIsolated {
            guard let game = tasks[id] else { return }
            if (200..<300).contains(code) {
                let target = localURL(for: game)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.moveItem(at: holding, to: target)
                } catch {
                    errorMessage = "Couldn't save \(game.file): \(error.localizedDescription)"
                }
                scanLocal()
            } else {
                errorMessage = "The server refused the download (HTTP \(code))."
                try? FileManager.default.removeItem(at: holding)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        MainActor.assumeIsolated {
            if let game = tasks[id] {
                progress[game.path] = nil
                tasks[id] = nil
                if let error, (error as? URLError)?.code != .cancelled {
                    errorMessage = "\(game.title) didn't finish downloading: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: Images

actor ArtCache {
    static let shared = ArtCache()
    private var cache: [URL: UIImage] = [:]
    private var missing: Set<URL> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        return URLSession(configuration: config)
    }()

    func image(_ url: URL) async -> UIImage? {
        if let hit = cache[url] { return hit }
        if missing.contains(url) { return nil }
        guard let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: result.0)?.preparingForDisplay() else {
            missing.insert(url)
            return nil
        }
        cache[url] = image
        return image
    }
}

enum Keychain {
    private static let service = "app.keepwatch.ossuary"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
