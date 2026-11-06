import Foundation
import WidgetKit

struct FrigateEvent: Identifiable {
    let id: String
    let camera: String
    let label: String
    let score: Double
    let startTime: Double
    let hasClip: Bool
    let hasSnapshot: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        camera = (json["camera"] as? String) ?? "camera"
        label = (json["label"] as? String) ?? "object"
        let data = json["data"] as? [String: Any]
        score = (json["top_score"] as? Double) ?? (data?["top_score"] as? Double) ?? (json["score"] as? Double) ?? 0
        startTime = (json["start_time"] as? Double) ?? Date().timeIntervalSince1970
        hasClip = (json["has_clip"] as? Bool) ?? false
        hasSnapshot = (json["has_snapshot"] as? Bool) ?? false
    }

    /// A minimal event for a deep link (`sentrycam://event/<id>`) when the full event isn't in memory.
    static func placeholder(id: String) -> FrigateEvent {
        FrigateEvent(json: ["id": id, "camera": "camera", "label": "event", "has_clip": true])!
    }
}

/// Talks to a standalone Frigate NVR. Logs in for the authenticated port (:8971) and keeps the cookie.
struct FrigateClient {
    let base: String
    let username: String
    let password: String

    init(address: String, username: String, password: String) {
        base = ServerAddress.normalize(address)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }

    private func url(_ path: String) throws -> URL {
        guard !base.isEmpty else { throw FrigateError.notConfigured }
        guard let u = URL(string: base + path), u.host != nil else { throw FrigateError.invalidURL }
        return u
    }

    func login() async throws {
        guard !username.isEmpty else { return }
        var request = URLRequest(url: try url("/api/login"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["user": username, "password": password])
        let (_, response) = try await httpSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FrigateError.loginFailed
        }
    }

    private func data(_ path: String, retry: Bool = true) async throws -> Data {
        var request = URLRequest(url: try url(path), timeoutInterval: 25)
        request.setValue("image/*, application/json, video/mp4", forHTTPHeaderField: "Accept")
        let (data, response) = try await httpSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            if (http.statusCode == 401 || http.statusCode == 403), retry, !username.isEmpty {
                try await login()
                return try await self.data(path, retry: false)
            }
            guard (200..<300).contains(http.statusCode) else { throw FrigateError.http(http.statusCode) }
        }
        return data
    }

    func cameras() async throws -> [String] {
        let bytes = try await data("/api/config")
        guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let cams = json["cameras"] as? [String: Any] else { return [] }
        return cams.keys.sorted()
    }

    func events(limit: Int = 50) async throws -> [FrigateEvent] {
        let bytes = try await data("/api/events?limit=\(limit)&include_thumbnails=0")
        guard let arr = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { return [] }
        return arr.compactMap { FrigateEvent(json: $0) }
    }

    func imageData(_ path: String) async throws -> Data { try await data(path) }

    /// Downloads a clip to a temp file (keeps TLS/auth on our session; AVPlayer then plays the local file).
    func downloadClip(_ id: String) async throws -> URL {
        let bytes = try await data("/api/events/\(id)/clip.mp4")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frigate-\(id).mp4")
        try bytes.write(to: file, options: .atomic)
        return file
    }

    func snapshotPath(_ camera: String, height: Int = 480) -> String {
        "/api/\(camera)/latest.jpg?h=\(height)&t=\(Int(Date().timeIntervalSince1970 * 1000))"
    }
    func thumbPath(_ id: String) -> String { "/api/events/\(id)/thumbnail.jpg" }
    func eventSnapshotPath(_ id: String) -> String { "/api/events/\(id)/snapshot.jpg" }

    /// Optional Tapo PTZ/patrol control through your NAS agent (antigravity exec).
    func runAgent(_ agentURL: String, command: String) async throws -> String {
        guard let u = URL(string: ServerAddress.normalize(agentURL) + "/api/antigravity/exec") else { throw FrigateError.invalidURL }
        var request = URLRequest(url: u, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["command": command])
        let (bytes, _) = try await httpSession.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let out = json["stdout"] as? String {
            return out.isEmpty ? "Done." : out
        }
        return "Sent."
    }
}

@MainActor
final class FrigateStore: ObservableObject {
    @Published var cameras: [String] = []
    @Published var events: [FrigateEvent] = []
    @Published var status: String?
    @Published var loading = false
    @Published var patrol: String?

    func start(_ settings: FrigateSettings) async {
        guard settings.isConfigured else { return }
        loading = true
        status = nil
        let client = settings.client
        do {
            if settings.needsLogin { try await client.login() }
            cameras = try await client.cameras()
            events = try await client.events(limit: 50)
            await updateWidget(client)
        } catch {
            status = describeError(error)
        }
        loading = false
    }

    /// Saves the latest snapshot + newest event to the App Group so the widget can show them.
    private func updateWidget(_ client: FrigateClient) async {
        var snapshot: Data?
        if let camera = cameras.first {
            snapshot = try? await client.imageData(client.snapshotPath(camera, height: 400))
        }
        let last = events.first.map {
            SharedStore.LastEvent(id: $0.id, label: $0.label, camera: $0.camera,
                                  time: Date(timeIntervalSince1970: $0.startTime))
        }
        SharedStore.save(event: last, snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reloadEvents(_ settings: FrigateSettings) async {
        guard settings.isConfigured else { return }
        do { events = try await settings.client.events(limit: 50) }
        catch { status = describeError(error) }
    }

    func runPatrol(_ settings: FrigateSettings, command: String, label: String) async {
        guard !settings.agentURL.isEmpty else { return }
        patrol = "\(label)…"
        do { patrol = try await settings.client.runAgent(settings.agentURL, command: command) }
        catch { patrol = "Couldn't reach the agent." }
    }
}
