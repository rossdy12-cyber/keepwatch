import Foundation
import UIKit

/// Your self-hosted Immich server (usually on the NAS). Address + API key come from
/// Immich's web app: Account Settings → API Keys. Stored in the Keychain.
struct ImmichSettings: Codable, Equatable {
    var address = ""   // e.g. http://100.85.127.42:2283  (the Immich web address)
    var key = ""       // an Immich API key

    var isConfigured: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty && base != nil }

    /// The API root, e.g. http://host:2283/api (we add /api if it isn't already there).
    var base: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.lowercased().hasSuffix("/api") { text += "/api" }
        return URL(string: text)
    }

    static func load() -> ImmichSettings { Keychain.load(ImmichSettings.self, for: "immich") ?? ImmichSettings() }
    func save() { Keychain.save(self, for: "immich") }
}

enum ImmichError: LocalizedError {
    case notSetUp, server(String), unreachable(String)
    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Add your Immich address and API key first."
        case .server(let message): return message
        case .unreachable(let detail): return "Couldn't reach Immich (\(detail)). For a 100.x address, check Tailscale is on."
        }
    }
}

/// One photo or video in your Immich library.
struct ImmichAsset: Identifiable, Hashable {
    let id: String
    let isVideo: Bool
    let fileName: String
    let durationSeconds: Double?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.isVideo = (json["type"] as? String)?.uppercased() == "VIDEO"
        self.fileName = (json["originalFileName"] as? String) ?? "Photo"
        // "0:00:12.34000" -> seconds
        if let duration = json["duration"] as? String {
            let parts = duration.split(separator: ":").map { Double($0) ?? 0 }
            if parts.count == 3 { self.durationSeconds = parts[0] * 3600 + parts[1] * 60 + parts[2] }
            else { self.durationSeconds = nil }
        } else { self.durationSeconds = nil }
    }
}

/// Talks to Immich: lists assets, fetches thumbnails, downloads originals.
/// Uploads are handled separately by ImmichBackup (with a retry queue).
struct ImmichClient {
    let settings: ImmichSettings
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private func makeRequest(_ path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        guard settings.isConfigured, let base = settings.base else { throw ImmichError.notSetUp }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw ImmichError.notSetUp }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(settings.key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func run(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ImmichError.unreachable(error.localizedDescription)
        }
    }

    /// Checks the address and key work; returns the signed-in user's name/email.
    func check() async throws -> String {
        let request = try makeRequest("users/me")
        let (data, status) = try await run(request)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 401 { throw ImmichError.server("Immich rejected the API key.") }
            throw ImmichError.server("Immich answered with HTTP \(status).")
        }
        return (json["name"] as? String) ?? (json["email"] as? String) ?? "Connected"
    }

    /// A page of assets, newest first. `page` is 1-based. Returns (assets, isLastPage).
    func assets(page: Int, size: Int = 120) async throws -> ([ImmichAsset], Bool) {
        var request = try makeRequest("search/metadata", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["page": page, "size": size, "order": "desc", "withExif": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await run(request)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String: Any], let items = assets["items"] as? [[String: Any]] else {
            throw ImmichError.server("Couldn't list your Immich photos (HTTP \(status)).")
        }
        let parsed = items.compactMap(ImmichAsset.init(json:))
        // `nextPage` is the next page number as a string, or null on the last page.
        let hasNextPage = (assets["nextPage"] as? String) != nil
        return (parsed, !hasNextPage || parsed.count < size)
    }

    /// A small thumbnail for the grid.
    func thumbnail(_ id: String) async throws -> Data {
        let request = try makeRequest("assets/\(id)/thumbnail", query: [URLQueryItem(name: "size", value: "thumbnail")])
        let (data, status) = try await run(request)
        guard status == 200 else { throw ImmichError.server("Thumbnail HTTP \(status).") }
        return data
    }

    /// The full-size original, for opening in the editor.
    func original(_ id: String) async throws -> Data {
        let request = try makeRequest("assets/\(id)/original")
        let (data, status) = try await run(request)
        guard status == 200 else { throw ImmichError.server("Download HTTP \(status).") }
        return data
    }
}
