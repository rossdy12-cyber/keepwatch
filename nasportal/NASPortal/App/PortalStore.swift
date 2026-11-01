import Foundation

/// A web page you can open from the Apps tab.
struct Site: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var symbol: String = "globe"

    var url: URL? { PortalStore.url(from: address) }
}

/// Settings and shortcuts, saved on the phone.
@MainActor
final class PortalStore: ObservableObject {
    private static let sitesKey = "portal.sites"
    private static let trueNASKey = "portal.truenas"
    private static let selfSignedKey = "portal.acceptSelfSigned"

    @Published var trueNASAddress: String {
        didSet { UserDefaults.standard.set(trueNASAddress, forKey: Self.trueNASKey) }
    }

    @Published var sites: [Site] {
        didSet {
            if let data = try? JSONEncoder().encode(sites) {
                UserDefaults.standard.set(data, forKey: Self.sitesKey)
            }
        }
    }

    @Published var acceptSelfSigned: Bool {
        didSet {
            UserDefaults.standard.set(acceptSelfSigned, forKey: Self.selfSignedKey)
            CertificatePolicy.acceptSelfSignedOnPrivateHosts = acceptSelfSigned
        }
    }

    init() {
        let defaults = UserDefaults.standard
        trueNASAddress = defaults.string(forKey: Self.trueNASKey) ?? "https://nas-server.co.uk"
        sites = defaults.data(forKey: Self.sitesKey).flatMap { try? JSONDecoder().decode([Site].self, from: $0) }
            ?? Self.defaultSites
        acceptSelfSigned = defaults.object(forKey: Self.selfSignedKey) as? Bool ?? true
        CertificatePolicy.acceptSelfSignedOnPrivateHosts = acceptSelfSigned
    }

    var trueNASURL: URL? { Self.url(from: trueNASAddress) }

    func resetSites() {
        sites = Self.defaultSites
    }

    static func url(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    static let defaultSites: [Site] = [
        Site(name: "Jarvis", address: "https://jarvis.nas-server.co.uk", symbol: "waveform.circle"),
        Site(name: "Frigate", address: "https://frigate.nas-server.co.uk", symbol: "video"),
        Site(name: "Jellyfin", address: "https://jellyfin.nas-server.co.uk", symbol: "play.tv"),
        Site(name: "Navidrome", address: "https://navidrome.nas-server.co.uk", symbol: "music.note"),
        Site(name: "Sonarr", address: "https://sonarr.nas-server.co.uk", symbol: "tv"),
        Site(name: "Radarr", address: "https://radarr.nas-server.co.uk", symbol: "film"),
        Site(name: "Lidarr", address: "https://lidarr.nas-server.co.uk", symbol: "music.mic"),
        Site(name: "Bazarr", address: "https://bazarr.nas-server.co.uk", symbol: "captions.bubble"),
        Site(name: "NZBGet", address: "https://nzbget.nas-server.co.uk", symbol: "arrow.down.circle"),
        Site(name: "Portainer", address: "https://portainer.nas-server.co.uk", symbol: "shippingbox"),
        Site(name: "Nginx Proxy Manager", address: "https://npm.nas-server.co.uk", symbol: "arrow.triangle.branch")
    ]

    static let symbolChoices = ["globe", "server.rack", "waveform.circle", "video", "play.tv", "music.note", "tv", "film",
                                "music.mic", "captions.bubble", "arrow.down.circle", "shippingbox", "arrow.triangle.branch",
                                "house", "photo", "doc", "lock.shield", "chart.bar", "cloud", "gearshape"]
}

/// Which servers may use self-signed certificates: only private addresses (Tailscale 100.x, home network, .local),
/// never public websites.
enum CertificatePolicy {
    static var acceptSelfSignedOnPrivateHosts = true

    static func allowsSelfSigned(host: String) -> Bool {
        guard acceptSelfSignedOnPrivateHosts else { return false }
        let host = host.lowercased()
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 && host.split(separator: ".").count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true // Tailscale / CGNAT
            default: return false
            }
        }
        if !host.contains(".") { return true }
        return [".ts.net", ".local", ".lan", ".home.arpa", ".internal"].contains { host.hasSuffix($0) }
    }
}
