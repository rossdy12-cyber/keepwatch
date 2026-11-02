import Foundation

struct ChatTurn: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    var failed = false
    /// Jarvis's own recording of this reply, when the core sends one.
    var audioURL: URL?
}

/// A piece of Jarvis's answer: more text, or a recording of Jarvis saying it.
enum ReplyPart {
    case text(String)
    case audio(URL)
}

enum HealthStatus: Equatable {
    case unknown
    case checking
    case online(String)
    case offline(String)
}

/// Talks to the Jarvis core over HTTP. Understands OpenAI-style, Ollama-style and plain JSON chat endpoints,
/// streamed (server-sent events or newline-delimited JSON) or not.
struct JarvisClient {
    let base: String
    let secrets: JarvisSecrets

    init(address: String, secrets: JarvisSecrets) {
        base = ServerAddress.normalize(address)
        self.secrets = secrets
    }

    // MARK: Requests

    func makeRequest(_ path: String, method: String = "GET", json: Any? = nil, timeout: TimeInterval = 20) throws -> URLRequest {
        guard !base.isEmpty else { throw JarvisError.notConfigured }
        let cleanPath = path.isEmpty || path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + cleanPath), url.host != nil else { throw JarvisError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = secrets.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let cfID = secrets.cfClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfSecret = secrets.cfClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cfID.isEmpty && !cfSecret.isEmpty {
            request.setValue(cfID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// `/v1/...` unless the address already ends in `/v1`.
    func openAIPath(_ path: String) -> String {
        base.lowercased().hasSuffix("/v1") ? path : "/v1" + path
    }

    /// Turns a non-2xx response (or a Cloudflare Access login page) into a `JarvisError`.
    static func check(_ response: URLResponse, body: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else { throw JarvisError.http(0, nil) }
        if let host = http.url?.host?.lowercased(), host.hasSuffix("cloudflareaccess.com") {
            throw JarvisError.cloudflareAccess
        }
        let code = http.statusCode
        if (200..<300).contains(code) { return }
        let fromCloudflare = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased().contains("cloudflare")
        if fromCloudflare && (520...530).contains(code) { throw JarvisError.cloudflare(code) }
        if code == 401 || code == 403 {
            if fromCloudflare, String(decoding: body.prefix(20_000), as: UTF8.self).contains("Cloudflare Access") {
                throw JarvisError.cloudflareAccess
            }
            throw JarvisError.unauthorized
        }
        if code == 404 { throw JarvisError.notFound(path) }
        var detail: String?
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            detail = extractText(json, keys: ["detail", "error", "message", "msg"])
        } else if !isHTML(response, body) {
            detail = String(decoding: body.prefix(300), as: UTF8.self)
        }
        throw JarvisError.http(code, detail?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isHTML(_ response: URLResponse, _ body: Data) -> Bool {
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("text/html") { return true }
        let start = String(decoding: body.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return start.hasPrefix("<!doctype html") || start.hasPrefix("<html")
    }

    func getJSON(_ path: String) async throws -> Any {
        let (data, response) = try await httpSession.data(for: makeRequest(path))
        try Self.check(response, body: data, path: path)
        if Self.isHTML(response, data) { throw JarvisError.webPage }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Chat

    /// Streams the reply to the last user message, chunk by chunk.
    func reply(history: [ChatTurn], endpoint: ResolvedEndpoint, systemPrompt: String, sessionID: String)
        -> AsyncThrowingStream<ReplyPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamReply(history: history, endpoint: endpoint, systemPrompt: systemPrompt,
                                          sessionID: sessionID) { _ = continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamReply(history: [ChatTurn], endpoint: ResolvedEndpoint, systemPrompt: String, sessionID: String,
                             emit: (ReplyPart) -> Void) async throws {
        let usable = history.filter { !$0.failed && !$0.text.isEmpty }
        var messages: [[String: String]] = []
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { messages.append(["role": "system", "content": prompt]) }
        messages += usable.suffix(30).map { ["role": $0.role.rawValue, "content": $0.text] }
        let latest = usable.last(where: { $0.role == .user })?.text ?? ""

        let path: String
        let body: [String: Any]
        switch endpoint.style {
        case .openAI, .auto:
            path = openAIPath("/chat/completions")
            body = ["model": endpoint.model, "messages": messages, "stream": true]
        case .ollama:
            path = "/api/chat"
            body = ["model": endpoint.model, "messages": messages, "stream": true]
        case .custom:
            path = endpoint.chatPath
            body = [endpoint.messageField: latest, "session_id": sessionID]
        }

        var request = try makeRequest(path, method: "POST", json: body, timeout: 300)
        request.setValue("text/event-stream, application/x-ndjson, application/json, text/plain", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await httpSession.bytes(for: request)

        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let ok = ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            && !((response as? HTTPURLResponse)?.url?.host?.lowercased().hasSuffix("cloudflareaccess.com") ?? false)

        var gotText = false
        if ok && type.contains("event-stream") {
            // Server-sent events: `data: {...}` lines, ending with `data: [DONE]`.
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                var payload = Substring(line.dropFirst(5))
                if payload.first == " " { payload = payload.dropFirst() }
                if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }
                let chunk: String?
                if let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    chunk = Self.extractText(json)
                } else {
                    chunk = String(payload)
                }
                if let chunk, !chunk.isEmpty { gotText = true; emit(.text(chunk)) }
            }
        } else if ok && type.contains("ndjson") {
            // Ollama: one JSON object per line.
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
                if let chunk = Self.extractText(json), !chunk.isEmpty { gotText = true; emit(.text(chunk)) }
            }
        } else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            try Self.check(response, body: data, path: path)
            if Self.isHTML(response, data) { throw JarvisError.webPage }
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                if let text = Self.extractText(json), !text.isEmpty { gotText = true; emit(.text(text)) }
                if let audio = audioURL(in: json) { emit(.audio(audio)) }
            } else {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { gotText = true; emit(.text(text)) }
            }
        }
        if !gotText { throw JarvisError.emptyReply }
    }

    /// Downloads one of Jarvis's voice recordings. The token is only sent to the Jarvis server itself.
    func fetchAudio(_ url: URL) async throws -> Data {
        var request = try makeRequest("", timeout: 60)
        let sameHost = request.url?.host?.lowercased() == url.host?.lowercased()
        if !sameHost { request = URLRequest(url: url, timeoutInterval: 60) }
        request.url = url
        request.setValue("audio/*, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await httpSession.data(for: request)
        try Self.check(response, body: data, path: url.path)
        return data
    }

    /// Jarvis can answer with a recording of its own voice: `{"reply": "…", "audio_url": "/voice/abc.mp3"}`.
    private func audioURL(in json: Any) -> URL? {
        guard let dict = json as? [String: Any] else { return nil }
        for key in ["audio_url", "audioUrl", "audio", "voice_url"] {
            guard let raw = dict[key] as? String, !raw.isEmpty else { continue }
            if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
            return URL(string: base + (raw.hasPrefix("/") ? raw : "/" + raw))
        }
        return nil
    }

    static let replyKeys = ["reply", "response", "answer", "output", "text", "content", "choices", "message",
                            "delta", "result", "data", "speech", "plain"]

    /// Digs the reply text out of a JSON answer: `{"reply": "…"}`, `{"choices":[{"message":{"content":"…"}}]}`,
    /// `{"message":{"content":"…"}}`, `{"response":{"speech":{"plain":{"speech":"…"}}}}` and so on.
    static func extractText(_ value: Any, keys: [String] = replyKeys, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            return array.first.flatMap { extractText($0, keys: keys, depth: depth + 1) }
        }
        if let dict = value as? [String: Any] {
            for key in keys + (keys == replyKeys ? [] : replyKeys) {
                if let inner = dict[key], let text = extractText(inner, keys: keys, depth: depth + 1) {
                    return text
                }
            }
        }
        return nil
    }

    // MARK: Health and detection

    func health(path: String) async -> HealthStatus {
        let probePath = path.trimmingCharacters(in: .whitespaces).isEmpty ? "/" : path
        do {
            let (data, response) = try await httpSession.data(for: makeRequest(probePath, timeout: 10))
            do {
                try Self.check(response, body: data, path: probePath)
                return .online("Online")
            } catch JarvisError.notFound {
                return .online("Online")
            } catch JarvisError.http(let code, _) where code < 500 {
                return .online("Online")
            }
        } catch {
            return .offline(describe(error))
        }
    }

    /// Looks for an OpenAI-compatible API, then Ollama, then an OpenAPI description of a custom endpoint.
    /// Throws only when the server can't be reached at all.
    func detect() async throws -> Detection {
        if let json = try await probe(openAIPath("/models")) as? [String: Any],
           let list = json["data"] as? [[String: Any]] {
            let models = list.compactMap { $0["id"] as? String }
            return Detection(style: .openAI, models: models,
                             summary: "OpenAI-compatible API, \(models.count) model\(models.count == 1 ? "" : "s").")
        }
        if let json = try await probe("/api/tags") as? [String: Any],
           let list = json["models"] as? [[String: Any]] {
            let models = list.compactMap { ($0["name"] ?? $0["model"]) as? String }
            return Detection(style: .ollama, models: models,
                             summary: "Ollama API, \(models.count) model\(models.count == 1 ? "" : "s").")
        }
        for specPath in ["/openapi.json", "/api/openapi.json", "/docs/openapi.json", "/api/v1/openapi.json"] {
            guard let spec = try await probe(specPath) as? [String: Any] else { continue }
            if let paths = spec["paths"] as? [String: Any], paths.keys.contains(where: { $0.hasSuffix("/chat/completions") }) {
                return Detection(style: .openAI, summary: "OpenAI-compatible API (found in \(specPath)).")
            }
            if let found = Self.chatEndpoint(in: spec) {
                return Detection(style: .custom, chatPath: found.path, messageField: found.field,
                                 summary: "Custom API: POST \(found.path) with \"\(found.field)\" (found in \(specPath)).")
            }
        }
        return Detection(style: .custom,
                         summary: "Jarvis is reachable, but its API wasn't recognised. Using the custom endpoint settings below.")
    }

    /// GETs a path and returns its JSON, or nil when it isn't there. Throws for connection-level problems.
    private func probe(_ path: String) async throws -> Any? {
        do {
            return try await getJSON(path)
        } catch let error as JarvisError {
            switch error {
            case .notFound, .http, .webPage, .emptyReply: return nil
            default: throw error
            }
        } catch is DecodingError {
            return nil
        } catch let error as URLError {
            throw error
        } catch {
            return nil // not JSON
        }
    }

    /// Picks the most chat-like POST endpoint from an OpenAPI document, and the name of its message field.
    static func chatEndpoint(in spec: [String: Any]) -> (path: String, field: String)? {
        guard let paths = spec["paths"] as? [String: Any] else { return nil }
        let words: [(String, Int)] = [("chat", 5), ("converse", 4), ("conversation", 4), ("ask", 4), ("assistant", 3),
                                      ("message", 3), ("prompt", 3), ("query", 2), ("command", 2), ("jarvis", 2),
                                      ("process", 1), ("text", 1)]
        var best: (path: String, score: Int, op: [String: Any])?
        for path in paths.keys.sorted() {
            guard !path.contains("{"), let ops = paths[path] as? [String: Any],
                  let post = ops["post"] as? [String: Any] else { continue }
            let lower = path.lowercased()
            if lower.contains("history") || lower.contains("upload") || lower.contains("login") { continue }
            let score = words.reduce(0) { $0 + (lower.contains($1.0) ? $1.1 : 0) }
            guard score > 0 else { continue }
            if best == nil || score > best!.score || (score == best!.score && path.count < best!.path.count) {
                best = (path, score, post)
            }
        }
        guard let best else { return nil }
        return (best.path, messageField(of: best.op, spec: spec))
    }

    private static func messageField(of operation: [String: Any], spec: [String: Any]) -> String {
        let preferred = ["message", "text", "prompt", "query", "input", "content", "question", "command", "utterance", "q"]
        guard let body = operation["requestBody"] as? [String: Any],
              let content = body["content"] as? [String: Any],
              let json = (content["application/json"] ?? content.values.first) as? [String: Any],
              var schema = json["schema"] as? [String: Any] else { return "message" }
        if let ref = schema["$ref"] as? String, let resolved = resolve(ref, in: spec) { schema = resolved }
        if let all = schema["allOf"] as? [[String: Any]], let first = all.first {
            schema = (first["$ref"] as? String).flatMap { resolve($0, in: spec) } ?? first
        }
        guard let properties = schema["properties"] as? [String: Any] else { return "message" }
        if let match = preferred.first(where: { properties[$0] != nil }) { return match }
        let required = schema["required"] as? [String] ?? []
        let strings = properties.keys.sorted().filter { ((properties[$0] as? [String: Any])?["type"] as? String) == "string" }
        return strings.first(where: { required.contains($0) }) ?? strings.first ?? "message"
    }

    private static func resolve(_ ref: String, in spec: [String: Any]) -> [String: Any]? {
        guard ref.hasPrefix("#/") else { return nil }
        var node: Any = spec
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let dict = node as? [String: Any], let next = dict[String(part)] else { return nil }
            node = next
        }
        return node as? [String: Any]
    }
}
