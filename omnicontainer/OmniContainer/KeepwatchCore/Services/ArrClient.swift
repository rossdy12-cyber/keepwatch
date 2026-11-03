import Foundation

/// Sonarr and Radarr (API v3) and Lidarr (API v1), authenticated with the `X-Api-Key` header.
struct ArrClient {
    let service: Service
    let base: String
    let apiKey: String

    init(service: Service, config: ServiceConfig) throws {
        guard !config.baseURL.isEmpty, URL(string: config.baseURL)?.host != nil, !config.apiKey.isEmpty else {
            throw APIError.notConfigured(service.title)
        }
        self.service = service
        base = config.baseURL
        apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var apiPrefix: String { service == .lidarr ? "/api/v1" : "/api/v3" }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> JSONValue {
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = makeURL(base: base, path: apiPrefix + path, query: items) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetchJSON(request, service: service.title)
    }

    /// Returns "Sonarr 4.0.9" etc., and checks that the right app answered.
    func testConnection() async throws -> String {
        let status = try await get("/system/status")
        let appName = status["appName"].string ?? ""
        let version = status["version"].string ?? "?"
        if !appName.isEmpty, appName.lowercased() != service.rawValue {
            throw APIError.server("That address is \(appName), not \(service.title). Check the port.")
        }
        if status["version"].isNull { throw APIError.notTheRightServer(service.title) }
        return "\(service.title) \(version)"
    }

    /// Picks the best artwork: the internet copy if there is one, otherwise the app's own cached copy.
    func imageURL(_ images: JSONValue, prefer types: [String]) -> URL? {
        let list = images.array
        for type in types + ["poster", "cover", "fanart", "banner"] {
            guard let image = list.first(where: { $0["coverType"].string == type }) else { continue }
            if let remote = image["remoteUrl"].string, let url = URL(string: remote) {
                return url
            }
            if let local = image["url"].string, var components = URLComponents(string: base + local) {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "apikey", value: apiKey)]
                return components.url
            }
        }
        return nil
    }
}
