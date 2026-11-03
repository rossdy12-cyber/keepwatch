import SwiftUI
import WebKit

struct MeshNode: Identifiable {
    let id: String
    let name: String
    let ip: String
    let role: String
    let keyPorts: [Int]
}

struct NodeProbeResult: Identifiable {
    let id: String
    let name: String
    let ip: String
    let latencyMs: Int?
    let openPorts: [Int]
}

struct DomainSSLStatus: Identifiable {
    var id: String { domain }
    let domain: String
    let status: String
    let isHealthy: Bool
}

@MainActor
class NetRadarStore: ObservableObject {
    let nodes: [MeshNode] = [
        MeshNode(id: "truenas", name: "TrueNAS SCALE Primary", ip: "100.85.127.42", role: "ZFS + 48 Docker Services", keyPorts: [80, 442, 3000, 5000, 9091, 9092, 30013, 30020, 31015]),
        MeshNode(id: "zima", name: "Zimaboard Secondary NAS", ip: "100.82.255.29", role: "LNAS + Portainer + Immich", keyPorts: [442, 2283, 9000, 10081]),
        MeshNode(id: "win", name: "Ross Windows 11 PC", ip: "100.102.4.54", role: "Antigravity #1 + Jellyfin + Steam", keyPorts: [7777, 8097, 8888, 9090]),
        MeshNode(id: "bazzite", name: "Bazzite Linux Gaming PC", ip: "100.79.246.119", role: "Antigravity #2 + SteamOS", keyPorts: [9091])
    ]

    let domains: [String] = [
        "nas-server.co.uk",
        "dashboard.nas-server.co.uk",
        "jellyfin.nas-server.co.uk",
        "immich.nas-server.co.uk",
        "nextcloud.nas-server.co.uk",
        "vaultwarden.nas-server.co.uk",
        "frigate.nas-server.co.uk",
        "sonarr.nas-server.co.uk",
        "radarr.nas-server.co.uk",
        "lidarr.nas-server.co.uk",
        "navidrome.nas-server.co.uk",
        "komga.nas-server.co.uk",
        "portainer.nas-server.co.uk",
        "lnas.nas-server.co.uk",
        "auth.nas-server.co.uk"
    ]

    @Published var results: [String: NodeProbeResult] = [:]
    @Published var sslResults: [DomainSSLStatus] = []
    @Published var customScanIP: String = "100.85.127.42"
    @Published var customScanOutput: String = "Tap Scan to probe ports or SSL expiry via TrueNAS."
    @Published var isScanning: Bool = false

    func scanMesh() async {
        isScanning = true
        defer { isScanning = false }
        for n in nodes {
            let start = Date()
            var open: [Int] = []
            var bestLatency: Int? = nil
            for p in n.keyPorts {
                guard let u = URL(string: "http://\(n.ip):\(p)") else { continue }
                var req = URLRequest(url: u)
                req.timeoutInterval = 1.6
                let t0 = Date()
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let _ = resp as? HTTPURLResponse {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    if bestLatency == nil || ms < bestLatency! { bestLatency = ms }
                    open.append(p)
                }
            }
            let _ = start
            results[n.id] = NodeProbeResult(id: n.id, name: n.name, ip: n.ip, latencyMs: bestLatency, openPorts: open)
        }
    }

    func auditDomainsSSL() async {
        isScanning = true
        defer { isScanning = false }
        var list: [DomainSSLStatus] = []
        for d in domains {
            guard let url = URL(string: "https://\(d)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 3.5
            let t0 = Date()
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                list.append(DomainSSLStatus(domain: d, status: "HTTPS \(code) • \(ms)ms • TLS Valid", isHealthy: true))
            } catch {
                list.append(DomainSSLStatus(domain: d, status: error.localizedDescription, isHealthy: false))
            }
        }
        sslResults = list
    }

    func runDeepNmapViaTrueNAS() async {
        isScanning = true
        defer { isScanning = false }
        guard let url = URL(string: "http://100.85.127.42:9092/api/antigravity/exec") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "tailscale status 2>/dev/null | head -n 15; echo '---'; ping -c 2 \(customScanIP) 2>&1"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let out = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? ""
            customScanOutput = out.isEmpty ? "Completed." : out
        }
    }
}

struct SpeedTestWebView: UIViewRepresentable {
    let urlString: String
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        if let u = URL(string: urlString) { w.load(URLRequest(url: u)) }
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct NetRadarApp: App {
    @StateObject private var store = NetRadarStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                MeshScannerTab()
                    .tabItem { Label("Tailscale Mesh", systemImage: "network") }
                SSLAuditorTab()
                    .tabItem { Label("SSL & NPM", systemImage: "lock.shield.fill") }
                SpeedTestTab()
                    .tabItem { Label("SpeedTest", systemImage: "speedometer") }
            }
            .environmentObject(store)
            .tint(.cyan)
            .preferredColorScheme(.dark)
            .task {
                await store.scanMesh()
            }
        }
    }
}

struct MeshScannerTab: View {
    @EnvironmentObject var store: NetRadarStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("4-Node Tailscale & Service Probe")
                            .font(.headline)
                        Spacer()
                        Button {
                            Task { await store.scanMesh() }
                        } label: {
                            Label(store.isScanning ? "Scanning..." : "Rescan", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ForEach(store.nodes) { n in
                        let res = store.results[n.id]
                        let online = (res?.openPorts.isEmpty == false)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(online ? Color.green : Color.orange)
                                    .frame(width: 10, height: 10)
                                Text(n.name).font(.subheadline.bold())
                                Spacer()
                                if let ms = res?.latencyMs {
                                    Text("\(ms) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.cyan)
                                }
                            }
                            Text("\(n.ip) • \(n.role)")
                                .font(.caption2)
                                .foregroundColor(.gray)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(n.keyPorts, id: \.self) { p in
                                        let isOpen = res?.openPorts.contains(p) ?? false
                                        Text(":\(p)")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(isOpen ? Color.green.opacity(0.25) : Color.white.opacity(0.06))
                                            .foregroundColor(isOpen ? .green : .gray)
                                            .cornerRadius(6)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                    }

                    Divider().background(Color.white.opacity(0.15))

                    Text("Live Tailscale Mesh Table (via TrueNAS)")
                        .font(.subheadline.bold())
                    HStack {
                        TextField("Target IP / Host", text: $store.customScanIP)
                            .textFieldStyle(.roundedBorder)
                        Button("Run Probe") {
                            Task { await store.runDeepNmapViaTrueNAS() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text(store.customScanOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("NetRadar")
        }
    }
}

struct SSLAuditorTab: View {
    @EnvironmentObject var store: NetRadarStore

    var body: some View {
        NavigationStack {
            List {
                Section("Nginx Proxy Manager (*.nas-server.co.uk)") {
                    ForEach(store.sslResults) { item in
                        HStack {
                            Image(systemName: item.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(item.isHealthy ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.domain).font(.subheadline.bold())
                                Text(item.status).font(.caption2).foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("SSL & Proxy Health")
            .toolbar {
                Button("Verify All 15 Domains") {
                    Task { await store.auditDomainsSSL() }
                }
            }
            .task {
                if store.sslResults.isEmpty {
                    await store.auditDomainsSSL()
                }
            }
        }
    }
}

struct SpeedTestTab: View {
    @State private var mode: Int = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Tool", selection: $mode) {
                Text("OpenSpeedTest (:30116)").tag(0)
                Text("NPM Admin (:30020)").tag(1)
                Text("Authelia (:9091)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(10)

            if mode == 0 {
                SpeedTestWebView(urlString: "http://100.85.127.42:30116")
                    .id("ost")
            } else if mode == 1 {
                SpeedTestWebView(urlString: "http://100.85.127.42:30020")
                    .id("npm")
            } else {
                SpeedTestWebView(urlString: "http://100.85.127.42:9091")
                    .id("authelia")
            }
        }
    }
}
