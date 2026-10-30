import Foundation

enum Service: String, CaseIterable, Identifiable, Codable {
    case truenas, nzbget, sonarr, radarr, lidarr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .truenas: return "TrueNAS"
        case .nzbget: return "NZBGet"
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .lidarr: return "Lidarr"
        }
    }

    var symbol: String {
        switch self {
        case .truenas: return "server.rack"
        case .nzbget: return "arrow.down.circle"
        case .sonarr: return "tv"
        case .radarr: return "film"
        case .lidarr: return "music.note"
        }
    }

    var usesLogin: Bool { self == .nzbget }

    var addressExample: String {
        self == .truenas ? "https://100.x.x.x" : "http://100.x.x.x:port"
    }

    var keyHelp: String {
        switch self {
        case .truenas: return "TrueNAS → Credentials → API Keys → Add"
        case .nzbget: return "NZBGet → Settings → Security → ControlUsername / ControlPassword"
        case .sonarr, .radarr, .lidarr: return "\(title) → Settings → General → API Key"
        }
    }
}

struct ServiceConfig: Codable, Equatable {
    var address: String = ""
    var apiKey: String = ""
    var username: String = ""
    var password: String = ""
    var acceptSelfSigned: Bool = true

    var baseURL: String { ServerAddress.normalize(address) }

    var isConfigured: Bool {
        !baseURL.isEmpty && (!apiKey.isEmpty || !username.isEmpty || !password.isEmpty)
    }
}

/// Holds every service's address and key, persisted in the Keychain.
@MainActor
final class ServiceSettings: ObservableObject {
    @Published private(set) var configs: [Service: ServiceConfig] = [:]

    init() {
        for service in Service.allCases {
            let config = Keychain.load(ServiceConfig.self, for: service.rawValue) ?? ServiceConfig()
            configs[service] = config
            applyTrust(service, config)
        }
    }

    subscript(service: Service) -> ServiceConfig {
        configs[service] ?? ServiceConfig()
    }

    func update(_ service: Service, _ config: ServiceConfig) {
        guard configs[service] != config else { return }
        configs[service] = config
        Keychain.save(config, for: service.rawValue)
        applyTrust(service, config)
    }

    var anyConfigured: Bool {
        Service.allCases.contains { self[$0].isConfigured }
    }

    private func applyTrust(_ service: Service, _ config: ServiceConfig) {
        guard service == .truenas else { return }
        TrustDelegate.shared.setTrusted(host: URL(string: config.baseURL)?.host, trusted: config.acceptSelfSigned)
    }
}
