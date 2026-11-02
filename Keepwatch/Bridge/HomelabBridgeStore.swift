import Foundation
import SwiftUI

struct DockerContainerInfo: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String

    var isRunning: Bool {
        state.lowercased() == "running"
    }
}

struct FrigateCameraInfo: Identifiable, Codable, Equatable {
    let id: String
    let name: String
}

struct FrigateEventInfo: Identifiable, Codable, Equatable {
    let id: String
    let camera: String
    let label: String
    let score: Int
    let startTime: Double

    var formattedTime: String {
        guard startTime > 0 else { return "Just now" }
        let date = Date(timeIntervalSince1970: startTime)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct AppleServiceInfo: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    let state: String
    let status: String
    let needs2FA: Bool
    let lastLog: String

    var displayName: String {
        switch name {
        case "icloudpd": return "iCloud Photos (Main)"
        case "icloudpd-hidden": return "iCloud Photos (Hidden)"
        case "icloudpd-shared": return "iCloud Photos (Shared)"
        case "altserver": return "AltServer IPA Signer"
        case "anisette-v3": return "Anisette Apple Auth Server"
        case "album-ross": return "Immich Face Album (Ross)"
        case "album-ross-and-lauren": return "Immich Face Album (Ross & Lauren)"
        default: return name
        }
    }
}

struct JellyseerrItem: Identifiable, Codable, Equatable {
    let id: Int
    let mediaType: String
    let title: String
    let year: String
    let overview: String
    let poster: String
    var status: Int // 1=unknown, 2=pending, 3=processing, 4=partial, 5=available

    var statusLabel: String {
        switch status {
        case 5: return "Available"
        case 4: return "Partial"
        case 3: return "Processing"
        case 2: return "Requested"
        default: return "Request"
        }
    }
}

struct JarvisAlarmItem: Identifiable, Codable, Equatable {
    let id: String
    let time: String
    let label: String
    var enabled: Bool
}

struct SharedChecklistItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var done: Bool
}

struct DropHistoryItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let query: String
    let target: String
    let message: String
    let timestamp: Date
}

@MainActor
final class HomelabBridgeStore: ObservableObject {
    static let shared = HomelabBridgeStore()

    @Published var containers: [DockerContainerInfo] = []
    @Published var cameras: [FrigateCameraInfo] = [
        FrigateCameraInfo(id: "tapo_c200", name: "Tapo C200 (Garden/Porch)"),
        FrigateCameraInfo(id: "bike_camera", name: "Bike Camera"),
        FrigateCameraInfo(id: "doorbell", name: "Front Doorbell")
    ]
    @Published var cameraEvents: [FrigateEventInfo] = []
    @Published var patrolRunning = true
    @Published var alertsEnabled = true
    @Published var snapshotBuster = Int(Date().timeIntervalSince1970)

    @Published var appleServices: [AppleServiceInfo] = []
    @Published var discoverItems: [JellyseerrItem] = []
    @Published var tdarrRunning = true

    @Published var desktopOllamaOnline = false
    @Published var alarms: [JarvisAlarmItem] = []
    @Published var sharedNotes: [SharedChecklistItem] = []

    @Published var dropHistory: [DropHistoryItem] = []
    @Published var statusBanner: String?
    @Published var isLoading = false

    private let notesFallbackKey = "keepwatch.sharedNotes.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: notesFallbackKey),
           let decoded = try? JSONDecoder().decode([SharedChecklistItem].self, from: data) {
            sharedNotes = decoded
        } else {
            sharedNotes = [
                SharedChecklistItem(id: "1", text: "09:00 Morning Handover check-in", done: false),
                SharedChecklistItem(id: "2", text: "15:00 School Run / Afternoon Prep", done: false),
                SharedChecklistItem(id: "3", text: "18:00 Dinner & Kitchen Reset", done: false)
            ]
        }
    }

    var baseURL: String {
        let configured = JarvisSettings.shared.config.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            var base = configured
            if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
                base = "https://" + base
            }
            while base.hasSuffix("/") { base.removeLast() }
            return base
        }
        return "https://jarvis.nas-server.co.uk"
    }

    private func session() -> URLSession {
        if let host = URL(string: baseURL)?.host {
            TrustDelegate.shared.setTrusted(host: host, trusted: JarvisSettings.shared.config.trustSelfSigned)
        }
        return httpSession
    }

    private func applyHeaders(_ req: inout URLRequest) {
        let secrets = JarvisSettings.shared.secrets
        if !secrets.token.isEmpty {
            req.setValue("Bearer \(secrets.token)", forHTTPHeaderField: "Authorization")
        }
        if !secrets.cfClientID.isEmpty && !secrets.cfClientSecret.isEmpty {
            req.setValue(secrets.cfClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secrets.cfClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    // MARK: - 1. Docker Container Deck (All containers except iDrive)

    func loadContainers() async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/containers") else { return }
        var req = URLRequest(url: url)
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            struct Resp: Decodable { let containers: [DockerContainerInfo] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            containers = decoded.containers.filter { !$0.name.lowercased().contains("idrive") }
        } catch {
            statusBanner = describe(error)
        }
    }

    func containerAction(name: String, action: String) async {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/keepwatch/container/\(encoded)/\(action)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                statusBanner = msg
            }
            await loadContainers()
        } catch {
            statusBanner = describe(error)
        }
    }

    func fetchContainerLogs(name: String) async -> String {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/keepwatch/container/\(encoded)/logs?lines=100") else {
            return "Invalid container URL."
        }
        var req = URLRequest(url: url)
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let logs = json["logs"] as? String {
                return logs.isEmpty ? "No recent log output." : logs
            }
        } catch {
            return describe(error)
        }
        return "Unable to load logs."
    }

    // MARK: - 2. Drop-to-NAS Universal Media Grabber

    func dropToNAS(urlOrQuery: String, target: String = "auto") async -> String {
        let trimmed = urlOrQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(baseURL)/api/keepwatch/drop") else {
            return "Enter a link or search query first."
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": trimmed, "target": target])
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = (json["message"] as? String) ?? (json["error"] as? String) ?? "Sent to NAS."
                let resolvedTarget = (json["target"] as? String) ?? target
                dropHistory.insert(
                    DropHistoryItem(query: trimmed, target: resolvedTarget, message: msg, timestamp: Date()),
                    at: 0
                )
                statusBanner = msg
                return msg
            }
        } catch {
            let err = describe(error)
            statusBanner = err
            return err
        }
        return "Sent to NAS."
    }

    // MARK: - 3. Frigate Cameras, Tapo Patrol & Smart Doorbell

    func loadCameras() async {
        snapshotBuster = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "\(baseURL)/api/keepwatch/cameras") else { return }
        var req = URLRequest(url: url)
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            struct Resp: Decodable {
                let cameras: [FrigateCameraInfo]
                let events: [FrigateEventInfo]
                let patrolRunning: Bool
                let alertsEnabled: Bool
            }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            if !decoded.cameras.isEmpty { cameras = decoded.cameras }
            cameraEvents = decoded.events
            patrolRunning = decoded.patrolRunning
            alertsEnabled = decoded.alertsEnabled
        } catch {
            statusBanner = describe(error)
        }
    }

    func snapshotURL(for cameraID: String) -> URL? {
        URL(string: "\(baseURL)/api/keepwatch/camera/\(cameraID)/snapshot?t=\(snapshotBuster)")
    }

    func eventThumbnailURL(for eventID: String) -> URL? {
        URL(string: "\(baseURL)/api/keepwatch/event/\(eventID)/thumbnail")
    }

    func cameraAction(_ action: String) async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/cameras/action") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action])
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                statusBanner = msg
            }
            await loadCameras()
        } catch {
            statusBanner = describe(error)
        }
    }

    // MARK: - 4. Apple Re-Auth (iCloudPD & AltServer) & Immich Face Albums

    func loadAppleServices() async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/apple-services") else { return }
        var req = URLRequest(url: url)
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            struct Resp: Decodable { let services: [AppleServiceInfo] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            appleServices = decoded.services
        } catch {
            statusBanner = describe(error)
        }
    }

    func appleServiceAction(action: String, container: String = "icloudpd", code: String = "") async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/apple-services/action") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": action,
            "container": container,
            "code": code
        ])
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                statusBanner = msg
            }
            await loadAppleServices()
        } catch {
            statusBanner = describe(error)
        }
    }

    // MARK: - 5. Jellyseerr Discover & Tdarr Pipeline

    func loadMediaPipeline(query: String = "") async {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(baseURL)/api/keepwatch/media-pipeline?q=\(encoded)") else { return }
        var req = URLRequest(url: url)
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            struct Resp: Decodable {
                let items: [JellyseerrItem]
                let tdarrRunning: Bool
            }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            discoverItems = decoded.items
            tdarrRunning = decoded.tdarrRunning
        } catch {
            statusBanner = describe(error)
        }
    }

    func requestJellyseerr(item: JellyseerrItem) async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/media-pipeline/request") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "mediaId": item.id,
            "mediaType": item.mediaType
        ])
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                statusBanner = msg
            }
            if let idx = discoverItems.firstIndex(where: { $0.id == item.id }) {
                discoverItems[idx].status = 2
            }
        } catch {
            statusBanner = describe(error)
        }
    }

    func toggleTdarr() async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/media-pipeline/tdarr") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let running = json["tdarrRunning"] as? Bool { tdarrRunning = running }
                if let msg = json["message"] as? String { statusBanner = msg }
            }
        } catch {
            statusBanner = describe(error)
        }
    }

    // MARK: - 6. System Bridge (Desktop GPU, Smart Alarms, Broadcast & Shared Handover Notes)

    func loadSystemBridge() async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/system-bridge") else { return }
        var req = URLRequest(url: url)
        applyHeaders(&req)
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                desktopOllamaOnline = (json["desktopOllamaOnline"] as? Bool) ?? false
                if let rawAlarms = json["alarms"] as? [[String: Any]] {
                    alarms = rawAlarms.compactMap { dict in
                        let t = (dict["time"] as? String) ?? ""
                        guard !t.isEmpty else { return nil }
                        let id = (dict["id"] as? String) ?? t
                        let label = (dict["label"] as? String) ?? "Jarvis Alarm"
                        let enabled = (dict["enabled"] as? Bool) ?? true
                        return JarvisAlarmItem(id: id, time: t, label: label, enabled: enabled)
                    }
                }
                if let rawNotes = json["notes"],
                   let notesData = try? JSONSerialization.data(withJSONObject: rawNotes),
                   let decodedNotes = try? JSONDecoder().decode([SharedChecklistItem].self, from: notesData),
                   !decodedNotes.isEmpty {
                    sharedNotes = decodedNotes
                    UserDefaults.standard.set(notesData, forKey: notesFallbackKey)
                }
            }
        } catch {
            // Keep local cached notes
        }
    }

    func addAlarm(time: String, label: String) async {
        await systemBridgeAction(["action": "add_alarm", "time": time, "label": label])
    }

    func deleteAlarm(id: String) async {
        await systemBridgeAction(["action": "delete_alarm", "id": id])
    }

    func broadcastToHouse(message: String) async {
        await systemBridgeAction(["action": "broadcast", "message": message])
    }

    func sendPCCommand(_ command: String) async {
        await systemBridgeAction(["action": "pc_control", "command": command])
    }

    func saveSharedNotes(_ notes: [SharedChecklistItem]) async {
        sharedNotes = notes
        if let encoded = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(encoded, forKey: notesFallbackKey)
        }
        let dicts = notes.map { ["id": $0.id, "text": $0.text, "done": $0.done] as [String: Any] }
        await systemBridgeAction(["action": "save_notes", "notes": dicts])
    }

    private func systemBridgeAction(_ payload: [String: Any]) async {
        guard let url = URL(string: "\(baseURL)/api/keepwatch/system-bridge/action") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await session().data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                statusBanner = msg
            }
            await loadSystemBridge()
        } catch {
            statusBanner = describe(error)
        }
    }
}
