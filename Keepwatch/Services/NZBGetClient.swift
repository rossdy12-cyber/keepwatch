import Foundation

struct DownloadStatus {
    var rate: Double
    var remainingMB: Double
    var paused: Bool
    var freeDiskMB: Double?
    var limit: Double
}

struct QueueItem: Identifiable {
    var id: Int
    var name: String
    var status: String
    var category: String
    var sizeMB: Double
    var remainingMB: Double
    var pausedMB: Double

    var progress: Double { sizeMB > 0 ? max(0, min(1, (sizeMB - remainingMB) / sizeMB)) : 0 }
    var isPaused: Bool { status.uppercased().contains("PAUSED") }
}

struct HistoryItem: Identifiable {
    var id: Int
    var name: String
    var status: String
    var category: String
    var sizeMB: Double
    var date: Date?

    var succeeded: Bool { status.uppercased().hasPrefix("SUCCESS") }
}

/// NZBGet's JSON-RPC API at `/jsonrpc`, using the Control username and password.
struct NZBGetClient {
    let base: String
    let username: String
    let password: String

    init(config: ServiceConfig) throws {
        guard !config.baseURL.isEmpty, URL(string: config.baseURL)?.host != nil else { throw APIError.notConfigured("NZBGet") }
        base = config.baseURL
        username = config.username
        password = config.password
    }

    func call(_ method: String, _ params: [Any] = []) async throws -> JSONValue {
        guard let url = URL(string: base + "/jsonrpc") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": 1])
        let response = try await fetchJSON(request, service: "NZBGet")
        if !response["error"].isNull {
            throw APIError.server("NZBGet: " + (response["error"]["message"].string ?? "error"))
        }
        return response["result"]
    }

    func version() async throws -> String {
        try await call("version").string ?? "?"
    }

    func status() async throws -> DownloadStatus {
        let value = try await call("status")
        return DownloadStatus(
            rate: value["DownloadRate"].double ?? 0,
            remainingMB: value["RemainingSizeMB"].double ?? 0,
            paused: value["DownloadPaused"].bool ?? false,
            freeDiskMB: value["FreeDiskSpaceMB"].double,
            limit: value["DownloadLimit"].double ?? 0
        )
    }

    func queue() async throws -> [QueueItem] {
        try await call("listgroups").array.map { group in
            QueueItem(
                id: group["NZBID"].int ?? 0,
                name: group["NZBName"].string ?? "Unknown",
                status: group["Status"].string ?? "",
                category: group["Category"].string ?? "",
                sizeMB: group["FileSizeMB"].double ?? 0,
                remainingMB: group["RemainingSizeMB"].double ?? 0,
                pausedMB: group["PausedSizeMB"].double ?? 0
            )
        }
    }

    func history() async throws -> [HistoryItem] {
        try await call("history", [false]).array.prefix(100).map { item in
            HistoryItem(
                id: item["NZBID"].int ?? item["ID"].int ?? 0,
                name: item["Name"].string ?? item["NZBName"].string ?? "Unknown",
                status: item["Status"].string ?? "",
                category: item["Category"].string ?? "",
                sizeMB: item["FileSizeMB"].double ?? 0,
                date: item["HistoryTime"].double.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    func setPaused(_ paused: Bool) async throws {
        _ = try await call(paused ? "pausedownload" : "resumedownload")
    }

    func setPaused(_ paused: Bool, id: Int) async throws {
        _ = try await call("editqueue", [paused ? "GroupPause" : "GroupResume", "", [id]])
    }
}
