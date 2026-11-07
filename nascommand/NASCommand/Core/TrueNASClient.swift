import Foundation

/// Talks to the TrueNAS SCALE REST API (v2.0) with an API key as a bearer token.
struct TrueNASClient {
    let base: String      // e.g. https://nas-server.co.uk/api/v2.0
    let apiKey: String

    init(address: String, apiKey: String) {
        base = ServerAddress.normalize(address) + "/api/v2.0"
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request(_ path: String, method: String = "GET", body: Any? = nil, timeout: TimeInterval = 25) throws -> URLRequest {
        guard !ServerAddress.normalize(base).isEmpty, !apiKey.isEmpty else { throw NASError.notConfigured }
        let clean = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + clean), url.host != nil else { throw NASError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func run(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        let (data, response) = try await httpSession.data(for: request(path, method: method, body: body))
        guard let http = response as? HTTPURLResponse else { throw NASError.http(0, nil) }
        if http.statusCode == 401 || http.statusCode == 403 { throw NASError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            var detail: String?
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                detail = (json as? [String: Any])?["message"] as? String
                    ?? ((json as? [[String: Any]])?.first?["message"] as? String)
            }
            if detail == nil { detail = String(decoding: data.prefix(200), as: UTF8.self) }
            throw NASError.http(http.statusCode, detail)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NASError.notJSON }
    }

    // MARK: Reads

    func systemInfo() async throws -> SystemInfo {
        try decode(SystemInfo.self, from: try await run("/system/info"))
    }

    func pools() async throws -> [NASPool] {
        try decode([NASPool].self, from: try await run("/pool"))
    }

    func apps() async throws -> [NASApp] {
        try decode([NASApp].self, from: try await run("/app"))
    }

    func alerts() async throws -> [NASAlert] {
        try decode([NASAlert].self, from: try await run("/alert/list"))
    }

    // MARK: Control

    enum AppAction: String { case start, stop, redeploy }

    /// Start / stop / restart an app. TrueNAS takes the app name as the bare JSON body.
    func control(_ app: NASApp, _ action: AppAction) async throws {
        _ = try await run("/app/\(action.rawValue)", method: "POST", body: app.name)
    }

    /// A quick auth/connectivity check for Settings.
    func test() async throws -> String {
        let info = try await systemInfo()
        return info.hostname ?? "Connected"
    }
}
