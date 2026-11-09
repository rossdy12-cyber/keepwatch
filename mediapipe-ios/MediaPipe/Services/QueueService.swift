import Foundation
import SocketIO

struct QueueDiagnostic: Identifiable, Hashable {
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
final class QueueService: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var diagnostics: [QueueDiagnostic] = []

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var settings: AppSettings
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    private let observedEvents = [
        "added", "updated", "completed", "deleted", "queue",
        "download-started", "download-progress", "download-finished",
        "download-error", "download-cancelled"
    ]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func connect() {
        disconnect()

        guard let baseURL = settings.serverProfile.normalizedBaseURL else {
            lastError = "Add a valid MeTube server URL in Settings."
            return
        }

        var config: [SocketIOClientOption] = [
            .log(false),
            .compress
        ]

        if settings.serverProfile.usesToken, !settings.apiToken.isEmpty {
            config.append(.extraHeaders(["Authorization": "Bearer \(settings.apiToken)"]))
        }

        let socketManager = SocketManager(socketURL: baseURL, config: config)
        let socket = socketManager.defaultSocket

        self.manager = socketManager
        self.socket = socket

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                self?.isConnected = true
                self?.lastError = nil
                self?.reconnectAttempt = 0
                self?.log("connect", "Connected to MeTube.")
            }
        }

        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                self?.isConnected = false
                self?.log("disconnect", "Disconnected from MeTube.")
                self?.scheduleReconnect()
            }
        }

        socket.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in
                self?.isConnected = false
                self?.lastError = "MeTube connection error."
                self?.log("error", "Socket.IO connection error.")
                self?.scheduleReconnect()
            }
        }

        for event in observedEvents {
            socket.on(event) { [weak self] data, _ in
                Task { @MainActor in
                    self?.handle(event: event, data: data)
                }
            }
        }

        socket.connect()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil

        socket?.disconnect()
        socket?.removeAllHandlers()
        socket = nil
        manager = nil
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
            let job = DownloadJob(
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

        for item in data {
            if let dictionary = item as? [String: Any] {
                payloads.append(dictionary)
            } else if let array = item as? [[String: Any]] {
                payloads.append(contentsOf: array)
            } else if let array = item as? [Any] {
                for nested in array {
                    if let dictionary = nested as? [String: Any] {
                        payloads.append(dictionary)
                    }
                }
            }
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

    private func upsert(_ job: DownloadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    private func log(_ event: String, _ message: String) {
        diagnostics.insert(
            QueueDiagnostic(event: event, message: message),
            at: 0
        )

        if diagnostics.count > 100 {
            diagnostics.removeLast(diagnostics.count - 100)
        }
    }

    private func uuid(from payload: [String: Any]) -> UUID? {
        guard let raw = string(from: payload, keys: ["id", "uid", "uuid", "download_id"]) else {
            return nil
        }

        return UUID(uuidString: raw)
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

    private func outputType(from payload: [String: Any]) -> OutputType {
        let value = string(from: payload, keys: ["format", "type", "output_type"])?.lowercased()

        if value == "audio" || value == "mp3" {
            return .audio
        }

        return .video
    }

    private func state(from payload: [String: Any], event: String) -> DownloadState {
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
