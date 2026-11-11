import Foundation

/// Talks to jarvis-core. Each companion sends its own persona + memory scope, so one core hosts many characters.
struct KithClient {
    let base: String
    let token: String

    init(coreURL: String, token: String) {
        base = ServerAddress.normalize(coreURL)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scope(_ companion: Companion) -> String { "kith-" + companion.id.uuidString }

    private func request(_ path: String, method: String = "GET", json: Any? = nil, timeout: TimeInterval = 90) throws -> URLRequest {
        guard !base.isEmpty else { throw KithError.notConfigured }
        guard let url = URL(string: base + path), url.host != nil else { throw KithError.invalidURL }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func reply(to message: String, companion: Companion, userName: String) async throws -> String {
        let body: [String: Any] = [
            "message": message,
            "session_id": scope(companion),
            "scope": scope(companion),
            "persona": companion.systemPrompt(userName: userName),
        ]
        do {
            return try await chatOnce(body)
        } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
            // A dropped/slow connection on the first try — give it one more go.
            try? await Task.sleep(nanoseconds: 800_000_000)
            return try await chatOnce(body)
        }
    }

    private func chatOnce(_ body: [String: Any]) async throws -> String {
        let (data, resp) = try await httpSession.data(for: try request("/api/chat", method: "POST", json: body, timeout: 120))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw KithError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = (obj["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty
        else { throw KithError.empty }
        return reply
    }

    func facts(companion: Companion) async throws -> [String] {
        let (data, resp) = try await httpSession.data(for: try request("/api/memory/facts?scope=\(scope(companion))", timeout: 20))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw KithError.http(http.statusCode) }
        let arr = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        return arr.compactMap { $0["text"] as? String }
    }

    func ping() async -> Bool {
        guard let req = try? request("/health", timeout: 15),
              let (_, resp) = try? await httpSession.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
