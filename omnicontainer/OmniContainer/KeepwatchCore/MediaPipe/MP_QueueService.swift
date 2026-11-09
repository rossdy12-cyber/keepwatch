import Foundation

struct MPQueueDiagnostic: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let event: String
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), event: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.event = event
        self.message = message
    }
}

@MainActor
final class MPQueueService: ObservableObject {
    @Published private(set) var jobs: [MPDownloadJob] = []
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var diagnostics: [MPQueueDiagnostic] = []

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var settings: MPAppSettings
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    private let observedEvents: Set<String> = [
        "all", "added", "updated", "completed", "canceled", "deleted", "queue",
        "download-started", "download-progress", "download-finished",
        "download-error", "download-cancelled"
    ]

    init(settings: MPAppSettings) {
        self.settings = settings
    }

    func updateSettings(_ settings: MPAppSettings) {
        self.settings = settings
    }

    func connect() {
        disconnect()

        guard let baseURL = settings.serverProfile.normalizedBaseURL,
              var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            lastError = "Add a valid MeTube server URL in Settings."
            return
        }

        Task { [weak self] in
            await self?.fetchHistorySnapshot(baseURL: baseURL)
        }

        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        let basePath = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.path = basePath.isEmpty ? "/socket.io/" : "/\(basePath)/socket.io/"
        comps.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket")
        ]

        guard let wsURL = comps.url else {
            lastError = "Could not construct MeTube WebSocket URL."
            return
        }

        var request = URLRequest(url: wsURL)
        if settings.serverProfile.usesToken, !settings.apiToken.isEmpty {
            request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.listenLoop(task: task)
        }
    }

    private func fetchHistorySnapshot(baseURL: URL) async {
        guard let historyURL = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/history") else {
            return
        }
        var req = URLRequest(url: historyURL)
        req.timeoutInterval = 15
        if settings.serverProfile.usesToken, !settings.apiToken.isEmpty {
            req.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        isConnected = true
        lastError = nil
        handle(event: "all", data: [json])
    }

    private func listenLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s):
                    text = s
                case .data(let d):
                    text = String(data: d, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }
                handleRawSocketIOPacket(text, task: task)
            } catch {
                if !Task.isCancelled {
                    isConnected = false
                    lastError = "MeTube connection error."
                    log("error", "Socket.IO connection closed: \(error.localizedDescription)")
                    scheduleReconnect()
                }
                break
            }
        }
    }

    private func handleRawSocketIOPacket(_ packet: String, task: URLSessionWebSocketTask) {
        guard !packet.isEmpty else { return }
        if packet.hasPrefix("0") {
            // Engine.IO open -> send Socket.IO connect ("40")
            task.send(.string("40")) { _ in }
        } else if packet == "2" {
            // Engine.IO ping -> send pong ("3")
            task.send(.string("3")) { _ in }
        } else if packet.hasPrefix("40") {
            isConnected = true
            lastError = nil
            reconnectAttempt = 0
            log("connect", "Connected to MeTube.")
        } else if packet.hasPrefix("41") {
            isConnected = false
            log("disconnect", "Disconnected from MeTube.")
            scheduleReconnect()
        } else if packet.hasPrefix("42") {
            let jsonPart = String(packet.dropFirst(2))
            guard let data = jsonPart.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let event = arr.first as? String else {
                return
            }
            let payloadArgs = Array(arr.dropFirst())
            if observedEvents.contains(event) {
                handle(event: event, data: payloadArgs)
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    func clearCompleted() {
        jobs.removeAll { $0.state == .completed }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()

        guard settings.isConfigured else { return }

        reconnectAttempt += 1
        let delay = min(Double(reconnectAttempt * 2), 30)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(event: String, data: [Any]) {
        log(event, describe(data))

        let payloads = decodedPayloads(from: data)

        guard !payloads.isEmpty else {
            return
        }

        if event == "deleted" {
            for payload in payloads {
                if let id = uuid(from: payload) {
                    jobs.removeAll { $0.id == id }
                }
            }

            return
        }

        for payload in payloads {
            let job = MPDownloadJob(
                id: uuid(from: payload) ?? UUID(),
                url: string(from: payload, keys: ["url", "link"]) ?? "",
                title: string(from: payload, keys: ["title", "name"]) ?? "Untitled download",
                outputType: outputType(from: payload),
                quality: string(from: payload, keys: ["quality", "quality_label"]) ?? "best",
                destination: string(from: payload, keys: ["folder", "output_folder"]) ?? "",
                state: state(from: payload, event: event),
                createdAt: date(from: payload) ?? Date(),
                errorMessage: string(from: payload, keys: ["error", "error_message"]),
                progress: progress(from: payload),
                downloadedBytes: int64(from: payload, keys: ["downloaded", "downloaded_bytes", "current_bytes"]),
                totalBytes: int64(from: payload, keys: ["total", "total_bytes", "filesize", "size"]),
                speed: string(from: payload, keys: ["speed", "download_speed"]),
                eta: string(from: payload, keys: ["eta", "remaining_time"]),
                thumbnailURL: string(from: payload, keys: ["thumbnail", "thumbnail_url", "image"]),
                lastEvent: event,
                lastEventAt: Date()
            )

            upsert(job)
        }
    }

    private func decodedPayloads(from data: [Any]) -> [[String: Any]] {
        var payloads: [[String: Any]] = []

        func extract(from item: Any) {
            if let str = item as? String,
               let strData = str.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: strData) {
                extract(from: parsed)
                return
            }
            if let dictionary = item as? [String: Any] {
                var foundBuckets = false
                for bucket in ["queue", "pending", "done"] {
                    if let arr = dictionary[bucket] as? [[String: Any]] {
                        payloads.append(contentsOf: arr)
                        foundBuckets = true
                    } else if let dictBucket = dictionary[bucket] as? [String: [String: Any]] {
                        payloads.append(contentsOf: dictBucket.values)
                        foundBuckets = true
                    }
                }
                if !foundBuckets {
                    payloads.append(dictionary)
                }
            } else if let array = item as? [Any] {
                for nested in array {
                    extract(from: nested)
                }
            }
        }

        for item in data {
            extract(from: item)
        }

        return payloads
    }

    private func describe(_ data: [Any]) -> String {
        guard let first = data.first else {
            return "No payload"
        }

        if let data = try? JSONSerialization.data(withJSONObject: [first], options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(1000))
        }

        return String(describing: first).prefix(1000).description
    }

    private func upsert(_ job: MPDownloadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    private func log(_ event: String, _ message: String) {
        diagnostics.insert(
            MPQueueDiagnostic(event: event, message: message),
            at: 0
        )

        if diagnostics.count > 100 {
            diagnostics.removeLast(diagnostics.count - 100)
        }
    }

    private func uuid(from payload: [String: Any]) -> UUID? {
        guard let raw = string(from: payload, keys: ["id", "uid", "uuid", "download_id", "url"]) else {
            return nil
        }

        if let u = UUID(uuidString: raw) {
            return u
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8 = Array(raw.utf8)
        for (i, b) in utf8.enumerated() {
            bytes[i % 16] = bytes[i % 16] &+ b &+ UInt8((i &* 31) & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func string(from payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func int64(from payload: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = payload[key] as? Int64 {
                return value
            }

            if let value = payload[key] as? Int {
                return Int64(value)
            }

            if let value = payload[key] as? Double {
                return Int64(value)
            }

            if let value = payload[key] as? String, let parsed = Int64(value) {
                return parsed
            }
        }

        return nil
    }

    private func progress(from payload: [String: Any]) -> Double? {
        for key in ["progress", "percent", "percentage"] {
            if let value = payload[key] as? Double {
                return value <= 1 ? value * 100 : value
            }

            if let value = payload[key] as? Int {
                return Double(value)
            }

            if let value = payload[key] as? String,
               let parsed = Double(value.replacingOccurrences(of: "%", with: "")) {
                return parsed
            }
        }

        return nil
    }

    private func outputType(from payload: [String: Any]) -> MPOutputType {
        let value = string(from: payload, keys: ["format", "type", "output_type"])?.lowercased()

        if value == "audio" || value == "mp3" {
            return .audio
        }

        return .video
    }

    private func state(from payload: [String: Any], event: String) -> MPDownloadState {
        if event == "completed" || event == "download-finished" {
            return .completed
        }

        if event == "download-error" {
            return .error
        }

        let status = string(from: payload, keys: ["status", "state"])?.lowercased()

        switch status {
        case "pending", "queued":
            return .pending
        case "downloading", "processing", "running":
            return .downloading
        case "finished", "completed", "done":
            return .completed
        case "error", "failed":
            return .error
        default:
            return .downloading
        }
    }

    private func date(from payload: [String: Any]) -> Date? {
        guard let raw = string(from: payload, keys: ["created", "created_at", "timestamp"]) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: raw)
    }
}
