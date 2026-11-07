import Foundation

/// GET /api/v2.0/system/info
struct SystemInfo: Decodable {
    let hostname: String?
    let version: String?
    let uptimeSeconds: Double?
    let physmem: Double?
    let cores: Int?
    let loadavg: [Double]?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case hostname, version, physmem, cores, loadavg, model
        case uptimeSeconds = "uptime_seconds"
    }
}

/// GET /api/v2.0/pool
struct NASPool: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: String?
    let healthy: Bool?
}

/// GET /api/v2.0/app  (TrueNAS SCALE Electric Eel and later, Docker apps)
struct NASApp: Decodable, Identifiable {
    let name: String
    let state: String?
    let humanVersion: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, state
        case humanVersion = "human_version"
        case id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Electric Eel uses "name"; some payloads use "id" as the release name.
        name = (try? c.decode(String.self, forKey: .name)) ?? (try? c.decode(String.self, forKey: .id)) ?? "unknown"
        state = try? c.decode(String.self, forKey: .state)
        humanVersion = try? c.decode(String.self, forKey: .humanVersion)
    }
}

/// GET /api/v2.0/alert/list
struct NASAlert: Decodable, Identifiable {
    let id: String
    let level: String?
    let formatted: String?
    let dismissed: Bool?
    let date: Date?

    enum CodingKeys: String, CodingKey {
        case id, level, formatted, dismissed, datetime
    }
    enum DateKeys: String, CodingKey { case date = "$date" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        level = try? c.decode(String.self, forKey: .level)
        formatted = try? c.decode(String.self, forKey: .formatted)
        dismissed = try? c.decode(Bool.self, forKey: .dismissed)
        if let dateContainer = try? c.nestedContainer(keyedBy: DateKeys.self, forKey: .datetime),
           let ms = try? dateContainer.decode(Double.self, forKey: .date) {
            date = Date(timeIntervalSince1970: ms / 1000.0)
        } else {
            date = nil
        }
    }
}

extension Double {
    /// Bytes to a short human size (e.g. 12.4 GB).
    var byteSize: String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = self, i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: value >= 100 || i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
    }
}

func shortUptime(_ seconds: Double) -> String {
    let d = Int(seconds) / 86400
    let h = (Int(seconds) % 86400) / 3600
    let m = (Int(seconds) % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
