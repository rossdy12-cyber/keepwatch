import Foundation

/// Talks to TrueNAS SCALE. It prefers the JSON-RPC 2.0 WebSocket API at `/api/current` (TrueNAS 25.04 and
/// newer), and falls back to the REST API at `/api/v2.0` on older systems where the WebSocket API is missing.
final class TrueNASClient {
    enum Mode: String {
        case websocket = "WebSocket API"
        case rest = "REST API"
    }

    let base: String
    private let apiKey: String

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var _mode: Mode?
    private var subscribedRealtime = false

    /// Called on the main queue with each `reporting.realtime` update (CPU, memory, network).
    var onRealtime: ((JSONValue) -> Void)?

    private(set) var serverVersion: String?

    init(config: ServiceConfig) throws {
        let base = config.baseURL
        guard !base.isEmpty, URL(string: base)?.host != nil else { throw APIError.invalidURL }
        guard base.lowercased().hasPrefix("https://") else { throw APIError.insecureTrueNAS }
        guard config.isPrivateHost || config.trustsDirectDomain else { throw APIError.proxiedTrueNAS }
        guard !config.apiKey.isEmpty else { throw APIError.notConfigured("TrueNAS") }
        self.base = base
        self.apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var mode: Mode? { locked { _mode } }

    // MARK: - Connecting

    func connect() async throws {
        if mode != nil { return }
        try await refuseCloudflare()

        var socketError: Error?
        do {
            try openSocket()
            let ok = try await socketCall("auth.login_with_api_key", [apiKey], timeout: 15)
            guard ok.bool == true else {
                close()
                throw APIError.unauthorized("TrueNAS")
            }
            locked { _mode = .websocket }
        } catch APIError.unauthorized(let service) {
            throw APIError.unauthorized(service)
        } catch {
            close()
            socketError = error
        }

        if mode == nil {
            // Older TrueNAS: no JSON-RPC WebSocket endpoint. Try REST before giving up.
            do {
                _ = try await restCall("system.info", [])
                locked { _mode = .rest }
            } catch let restError as APIError {
                if case .unauthorized = restError { throw restError }
                throw socketError ?? restError
            } catch {
                throw socketError ?? error
            }
        }

        serverVersion = try? await call("system.version").string
    }

    /// Makes one request without the key first. If Cloudflare answers, the key would reach TrueNAS over
    /// plain http and TrueNAS would revoke it, so it is never sent.
    private func refuseCloudflare() async throws {
        guard let url = URL(string: base + "/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await httpSession.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        let server = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        if server.contains("cloudflare") || http.value(forHTTPHeaderField: "CF-RAY") != nil {
            throw APIError.cloudflareTrueNAS
        }
    }

    func close() {
        let (oldTask, waiting) = locked { () -> (URLSessionWebSocketTask?, [CheckedContinuation<JSONValue, Error>]) in
            let old = task
            let waiting = Array(pending.values)
            task = nil
            pending = [:]
            _mode = nil
            subscribedRealtime = false
            return (old, waiting)
        }
        oldTask?.cancel(with: .goingAway, reason: nil)
        waiting.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }

    /// Asks TrueNAS to push live CPU, memory and network stats about once a second.
    func subscribeRealtime() async {
        guard mode == .websocket, !locked({ subscribedRealtime }) else { return }
        if (try? await socketCall("core.subscribe", ["reporting.realtime"])) != nil {
            locked { subscribedRealtime = true }
        }
    }

    // MARK: - Calls

    func call(_ method: String, _ params: [Any] = [], timeout: TimeInterval = 30) async throws -> JSONValue {
        switch mode {
        case .websocket:
            do {
                return try await socketCall(method, params, timeout: timeout)
            } catch let error as URLError {
                close()
                throw error
            }
        case .rest:
            return try await restCall(method, params)
        case nil:
            throw APIError.server("Not connected to TrueNAS.")
        }
    }

    /// Prepares a file for download with `core.download` + `filesystem.get` and returns its URL.
    func downloadURL(for path: String, filename: String) async throws -> URL {
        let result = try await call("core.download", ["filesystem.get", [path], filename])
        guard let relative = result[1].string, let url = URL(string: base + relative) else {
            throw APIError.server("TrueNAS didn't return a download link.")
        }
        return url
    }

    // MARK: - WebSocket transport

    private func openSocket() throws {
        guard var components = URLComponents(string: base) else { throw APIError.invalidURL }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/current"
        guard let url = components.url else { throw APIError.invalidURL }

        let socket = httpSession.webSocketTask(with: url)
        socket.maximumMessageSize = 32 * 1024 * 1024
        locked { task = socket }
        socket.resume()
        receiveNext(socket)
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                if self.locked({ self.task === socket }) { self.close() }
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let bytes): data = bytes
                @unknown default: break
                }
                if let data, let json = try? JSONValue.parse(data) {
                    self.handle(json)
                }
                self.receiveNext(socket)
            }
        }
    }

    private func handle(_ message: JSONValue) {
        if let id = message["id"].int {
            let error = message["error"]
            if error.isNull {
                resolve(id, .success(message["result"]))
            } else {
                let reason = error["data"]["reason"].string ?? error["message"].string ?? "TrueNAS returned an error."
                resolve(id, .failure(APIError.server(reason.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
            return
        }
        if message["method"].string == "collection_update" {
            let params = message["params"]
            if params["collection"].string == "reporting.realtime" {
                let fields = params["fields"]
                DispatchQueue.main.async { self.onRealtime?(fields) }
            }
        }
    }

    private func socketCall(_ method: String, _ params: [Any], timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let socket = locked({ task }) else { throw URLError(.networkConnectionLost) }
        let id: Int = locked {
            defer { nextId += 1 }
            return nextId
        }
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            locked { pending[id] = continuation }
            socket.send(.string(text)) { [weak self] error in
                if let error { self?.resolve(id, .failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(APIError.timeout))
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
        let continuation = locked { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    // MARK: - REST transport (TrueNAS 24.x and older)

    private func restCall(_ method: String, _ params: [Any]) async throws -> JSONValue {
        func first() -> Any { params.first ?? NSNull() }
        switch method {
        case "system.info": return try await rest("GET", "/system/info")
        case "system.version": return try await rest("GET", "/system/version")
        case "pool.query": return try await rest("GET", "/pool")
        case "disk.query": return try await rest("GET", "/disk")
        case "alert.list": return try await rest("GET", "/alert/list")
        case "app.query": return try await rest("GET", "/app")
        case "chart.release.query": return try await rest("GET", "/chart/release")
        case "disk.temperatures": return try await rest("POST", "/disk/temperatures", body: ["names": [String]()])
        case "smart.test.results": return try await rest("GET", "/smart/test/results")
        case "filesystem.listdir": return try await rest("POST", "/filesystem/listdir", body: ["path": first()])
        case "filesystem.stat": return try await rest("POST", "/filesystem/stat", body: first())
        case "core.download":
            let body: [String: Any] = [
                "method": params.count > 0 ? params[0] : "",
                "args": params.count > 1 ? params[1] : [Any](),
                "filename": params.count > 2 ? params[2] : "download"
            ]
            return try await rest("POST", "/core/download", body: body)
        default:
            throw APIError.server("\(method) isn't available on this TrueNAS version.")
        }
    }

    private func rest(_ httpMethod: String, _ path: String, body: Any? = nil) async throws -> JSONValue {
        guard let url = URL(string: base + "/api/v2.0" + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        }
        return try await fetchJSON(request, service: "TrueNAS")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
