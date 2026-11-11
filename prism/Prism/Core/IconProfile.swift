import Foundation
import Network
import UIKit

/// One themed home-screen icon to install via a configuration profile.
struct WebClip {
    let label: String
    let url: String      // what tapping the icon opens (an app URL scheme, or a web address)
    let iconPNG: Data    // the themed tile
}

/// Builds an Apple configuration profile (.mobileconfig) of web-clip icons. Installing it adds the
/// themed icons straight to the home screen — no Shortcuts steps.
enum ProfileBuilder {
    static func mobileconfig(_ clips: [WebClip], themeName: String) -> Data? {
        let payloads: [[String: Any]] = clips.map { clip in
            [
                "PayloadType": "com.apple.webClip.managed",
                "PayloadVersion": 1,
                "PayloadIdentifier": "app.prism.webclip.\(UUID().uuidString)",
                "PayloadUUID": UUID().uuidString.uppercased(),
                "PayloadDisplayName": clip.label,
                "URL": clip.url,
                "Label": clip.label,
                "Icon": clip.iconPNG,
                "IsRemovable": true,
                "Precomposed": true,
                "FullScreen": false,
            ]
        }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "app.prism.iconpack",
            "PayloadUUID": UUID().uuidString.uppercased(),
            "PayloadDisplayName": "Prism — \(themeName) icons",
            "PayloadDescription": "Themed home-screen icons from Prism. Remove any time from Settings ▸ General ▸ VPN & Device Management.",
            "PayloadOrganization": "Prism",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": payloads,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

/// Serves one .mobileconfig over localhost so Safari can download it and iOS offers to install it.
/// (iOS only triggers the profile-install flow for profiles fetched over http(s), not local files.)
final class ProfileServer {
    static let shared = ProfileServer()
    private var listener: NWListener?
    private var payload = Data()

    /// Starts serving `config` and calls back with the localhost URL to open in Safari.
    func start(serving config: Data, completion: @escaping (URL?) -> Void) {
        stop()
        payload = config
        guard let listener = try? NWListener(using: .tcp, on: .any) else { completion(nil); return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        var delivered = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !delivered, let port = listener.port?.rawValue {
                    delivered = true
                    completion(URL(string: "http://127.0.0.1:\(port)/prism.mobileconfig"))
                }
            case .failed, .cancelled:
                if !delivered { delivered = true; completion(nil) }
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        // Read (and ignore) the HTTP request, then reply with the profile.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            guard let self else { conn.cancel(); return }
            let body = self.payload
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/x-apple-aspen-config\r\n"
            head += "Content-Disposition: attachment; filename=\"prism.mobileconfig\"\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(body)
            conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
