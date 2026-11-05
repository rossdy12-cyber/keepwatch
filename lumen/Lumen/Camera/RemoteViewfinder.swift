import Foundation
import Network

/// A tiny web server that streams the live viewfinder (MJPEG) to any phone or laptop on the same
/// network, with a shutter button on the page. No app needed on the other device — just a browser.
final class RemoteViewfinder {
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "lumen.remoteviewfinder")
    var onShoot: (() -> Void)?

    private(set) var port: UInt16 = 0

    /// Starts the server. Calls back with the URL (http://<ip>:<port>) once it's listening, or nil on failure.
    func start(completion: @escaping (String?) -> Void) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { completion(nil); return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                self?.port = port
                let ip = RemoteViewfinder.localIPAddress() ?? "your-iPhone"
                completion("http://\(ip):\(port)")
            case .failed, .cancelled:
                completion(nil)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            for connection in self.streams.values { connection.cancel() }
            self.streams.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// Pushes one JPEG frame to every connected viewer.
    func broadcast(_ jpeg: Data) {
        queue.async {
            guard !self.streams.isEmpty else { return }
            var header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!
            header.append(jpeg)
            header.append("\r\n".data(using: .utf8)!)
            for (id, connection) in self.streams {
                connection.send(content: header, completion: .contentProcessed { error in
                    if error != nil { self.queue.async { self.streams[id]?.cancel(); self.streams[id] = nil } }
                })
            }
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = Self.requestPath(request)
            switch path {
            case "/": self.serve(connection, body: Self.page.data(using: .utf8)!, type: "text/html")
            case "/shoot": self.onShoot?(); self.serve(connection, body: Data("ok".utf8), type: "text/plain")
            case "/stream": self.startStream(connection)
            default: self.serve(connection, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain")
            }
        }
    }

    private func serve(_ connection: NWConnection, status: String = "200 OK", body: Data, type: String) {
        var response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".data(using: .utf8)!
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startStream(_ connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.queue.async { self.streams[ObjectIdentifier(connection)] = connection }
            } else {
                connection.cancel()
            }
        })
    }

    private static func requestPath(_ request: String) -> String {
        // First line looks like "GET /stream HTTP/1.1"
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1].split(separator: "?").first ?? "/")
    }

    /// The Wi-Fi (en0) IPv4 address, so the user knows where to point the other device.
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer?.pointee {
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || (address == nil && name.hasPrefix("en")) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    if name == "en0" { return ip }
                    address = ip
                }
            }
            pointer = interface.ifa_next
        }
        return address
    }

    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Lumen viewfinder</title></head>
    <body style="margin:0;background:#000;color:#fff;font-family:-apple-system,sans-serif;text-align:center">
    <img src="/stream" style="max-width:100%;max-height:82vh;object-fit:contain">
    <div style="padding:14px">
      <button onclick="fetch('/shoot')" style="width:74px;height:74px;border-radius:50%;border:5px solid #fff;background:#ffd60a">
      </button>
    </div>
    </body></html>
    """
}
