import SwiftUI
import WebKit
import UIKit

@main
struct EtherLauncherApp: App {
    @StateObject private var store = EtherStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    store.handleIncomingURL(url)
                }
        }
    }
}

struct IOSAppTile: Identifiable, Codable {
    var id: String
    var name: String
    var icon: String
    var scheme: String
    var colorHex: String
}

struct StockSummary: Codable {
    var totalSkus: Int = 42445
    var inStockCount: Int = 28903
    var lowStockCount: Int = 4491
    var outOfStockCount: Int = 9051
    var dailyRevenue: Double = 520.0
    var activeVisitors: Int = 62
    var cpu: Int = 18
    var mem: Int = 25
    var gpu: Int = 17
}

@MainActor
final class EtherStore: ObservableObject {
    @Published var serverHost: String = UserDefaults.standard.string(forKey: "ether_host") ?? "192.168.0.185:8787"
    @Published var summary = StockSummary()
    @Published var activeTab: Int = 0
    @Published var useLiveWebHUD: Bool = true
    @Published var accentMode: String = "blue"

    let defaultApps: [IOSAppTile] = [
        IOSAppTile(id: "phone", name: "Phone", icon: "phone.fill", scheme: "tel://", colorHex: "00e5a3"),
        IOSAppTile(id: "messages", name: "Messages", icon: "message.fill", scheme: "sms://", colorHex: "00e5a3"),
        IOSAppTile(id: "whatsapp", name: "WhatsApp", icon: "bubble.left.and.bubble.right.fill", scheme: "whatsapp://", colorHex: "25D366"),
        IOSAppTile(id: "safari", name: "Safari", icon: "safari.fill", scheme: "x-web-search://", colorHex: "00d4ff"),
        IOSAppTile(id: "icloud", name: "iCloud Mail", icon: "envelope.fill", scheme: "message://", colorHex: "00d4ff"),
        IOSAppTile(id: "outlook", name: "Work Mail", icon: "tray.full.fill", scheme: "ms-outlook://", colorHex: "0078D4"),
        IOSAppTile(id: "youtube", name: "YouTube", icon: "play.rectangle.fill", scheme: "youtube://", colorHex: "ff3b5c"),
        IOSAppTile(id: "spotify", name: "Spotify", icon: "music.note", scheme: "spotify://", colorHex: "1DB954"),
        IOSAppTile(id: "camera", name: "Camera", icon: "camera.fill", scheme: "camera://", colorHex: "f5b041"),
        IOSAppTile(id: "photos", name: "Photos", icon: "photo.fill", scheme: "photos-redirect://", colorHex: "ff8a00"),
        IOSAppTile(id: "maps", name: "Maps", icon: "map.fill", scheme: "maps://", colorHex: "00e5a3"),
        IOSAppTile(id: "notes", name: "Notes", icon: "note.text", scheme: "mobilenotes://", colorHex: "f5b041"),
        IOSAppTile(id: "calendar", name: "Calendar", icon: "calendar", scheme: "calshow://", colorHex: "ff3b5c"),
        IOSAppTile(id: "shortcuts", name: "Shortcuts", icon: "bolt.fill", scheme: "shortcuts://", colorHex: "a855f7"),
        IOSAppTile(id: "settings", name: "Settings", icon: "gearshape.fill", scheme: "App-Prefs://", colorHex: "94a3b8"),
        IOSAppTile(id: "racebolt", name: "Racebolt WP", icon: "wrench.and.screwdriver.fill", scheme: "https://raceboltuk.com/wp-admin/edit.php?post_type=product", colorHex: "00d4ff")
    ]

    init() {
        Task {
            await refreshTelemetry()
        }
    }

    func setHost(_ host: String) {
        serverHost = host
        UserDefaults.standard.set(host, forKey: "ether_host")
        Task { await refreshTelemetry() }
    }

    func handleIncomingURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if comps.host == "launch",
           let scheme = comps.queryItems?.first(where: { $0.name == "scheme" })?.value,
           let target = URL(string: scheme) {
            UIApplication.shared.open(target)
        } else if comps.host == "tab",
                  let idxStr = comps.queryItems?.first(where: { $0.name == "index" })?.value,
                  let idx = Int(idxStr) {
            activeTab = idx
        }
    }

    func launchApp(_ scheme: String) {
        guard let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url)
    }

    func installMobileConfig(mode: String) {
        let encodedHost = serverHost.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serverHost
        let urlStr = "http://\(serverHost)/api/ios/mobileconfig?mode=\(mode)&host=\(encodedHost)&accent=\(accentMode)"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
    }

    func refreshTelemetry() async {
        let candidates = [serverHost, "192.168.0.185:8787", "100.79.246.119:8787"]
        for host in candidates {
            guard let url = URL(string: "http://\(host)/api/state") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3.0
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if host != serverHost {
                        serverHost = host
                    }
                    if let stock = json["stock"] as? [String: Any],
                       let sum = stock["summary"] as? [String: Any] {
                        summary.totalSkus = sum["totalSkus"] as? Int ?? summary.totalSkus
                        summary.inStockCount = sum["inStockCount"] as? Int ?? summary.inStockCount
                        summary.lowStockCount = sum["lowStockCount"] as? Int ?? summary.lowStockCount
                        summary.outOfStockCount = sum["outOfStockCount"] as? Int ?? summary.outOfStockCount
                    }
                    if let ecom = json["ecommerce"] as? [String: Any],
                       let m = ecom["metrics"] as? [String: Any] {
                        summary.dailyRevenue = (m["dailyRevenue"] as? NSNumber)?.doubleValue ?? summary.dailyRevenue
                    }
                    if let ads = json["ads"] as? [String: Any],
                       let ga = ads["gaSummary"] as? [String: Any] {
                        summary.activeVisitors = ga["activeVisitors"] as? Int ?? summary.activeVisitors
                    }
                    if let tel = json["telemetry"] as? [String: Any] {
                        if let c = tel["cpu"] as? [String: Any] { summary.cpu = Int((c["percent"] as? NSNumber)?.doubleValue ?? 18) }
                        if let m = tel["memory"] as? [String: Any] { summary.mem = Int((m["percent"] as? NSNumber)?.doubleValue ?? 25) }
                        if let g = tel["gpu"] as? [String: Any] { summary.gpu = Int((g["utilization"] as? NSNumber)?.doubleValue ?? 17) }
                    }
                    return
                }
            } catch {
                continue
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: EtherStore

    var body: some View {
        ZStack {
            Color(red: 0.008, green: 0.02, blue: 0.043).ignoresSafeArea()

            if store.useLiveWebHUD, let url = URL(string: "http://\(store.serverHost)/iphone") {
                ZStack(alignment: .topTrailing) {
                    EtherWebHUDView(url: url)
                        .ignoresSafeArea()
                    Button(action: { store.useLiveWebHUD = false }) {
                        Text("NATIVE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.65))
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 12)
                }
            } else {
                NativeEtherLauncherView()
            }
        }
    }
}

struct EtherWebHUDView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                let scheme = (url.scheme ?? "").lowercased()
                if scheme != "http" && scheme != "https" && scheme != "about" {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
                if url.path.contains("/api/ios/mobileconfig") {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}

struct NativeEtherLauncherView: View {
    @EnvironmentObject var store: EtherStore

    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(spacing: 10) {
            // Top Status Strip
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Date(), style: .date)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                    Text(Date(), style: .time)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("THINK | PLAN | BUILD | EXECUTE")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                    Text("Æ  T  H  E  R")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                Spacer()
                Button(action: { store.useLiveWebHUD = true }) {
                    Text("LIVE HUD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.15))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 14)

            // Neural Orb
            NeuralOrbView()
                .frame(height: 170)

            // Quick Stats Strip
            HStack(spacing: 8) {
                StatPill(value: "\(store.summary.inStockCount)", label: "IN STOCK", color: .cyan)
                StatPill(value: String(format: "£%.0f", store.summary.dailyRevenue), label: "24H SALES", color: .cyan)
                StatPill(value: "● \(store.summary.activeVisitors)", label: "LIVE SITE", color: .green)
            }
            .padding(.horizontal, 14)

            // 4-Column App Launcher Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(store.defaultApps) { app in
                        Button(action: { store.launchApp(app.scheme) }) {
                            VStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.06))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                                        )
                                    Image(systemName: app.icon)
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(.cyan)
                                }
                                Text(app.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.02, green: 0.055, blue: 0.11).opacity(0.8))
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)

                // Home Screen Profile Installer Buttons
                VStack(spacing: 8) {
                    Button(action: { store.installMobileConfig(mode: "launcher") }) {
                        Label("Install Fullscreen ÆTHER Home Screen Profile", systemImage: "iphone.badge.play")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.cyan.opacity(0.2))
                            .foregroundColor(.cyan)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                    }
                    Button(action: { store.installMobileConfig(mode: "fullpack") }) {
                        Label("Install Full ÆTHER Custom Icon Pack (16 Apps)", systemImage: "square.grid.3x3.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(14)
            }
        }
    }
}

struct StatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(red: 0.02, green: 0.055, blue: 0.11).opacity(0.85))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.22), lineWidth: 1))
    }
}

struct NeuralOrbView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let r = min(size.width, size.height) * 0.38

                // Outer glow
                let glowRect = CGRect(x: cx - r * 1.4, y: cy - r * 1.4, width: r * 2.8, height: r * 2.8)
                context.fill(
                    Path(ellipseIn: glowRect),
                    with: .radialGradient(
                        Gradient(colors: [Color.cyan.opacity(0.35), Color.blue.opacity(0.08), .clear]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 2,
                        endRadius: r * 1.4
                    )
                )

                // 3D Fibonacci sphere nodes
                let count = 75
                let golden = Double.pi * (3.0 - sqrt(5.0))
                var pts: [(CGPoint, Double)] = []
                for i in 0..<count {
                    let y = 1.0 - (Double(i) / Double(count - 1)) * 2.0
                    let rad = sqrt(max(0, 1.0 - y * y))
                    let theta = golden * Double(i) + t * 0.45
                    let x = cos(theta) * rad
                    let z = sin(theta) * rad
                    let scale = 1.0 / (2.2 - z * 0.65)
                    let px = cx + CGFloat(x * Double(r) * scale * 1.8)
                    let py = cy + CGFloat(y * Double(r) * scale * 1.8)
                    pts.append((CGPoint(x: px, y: py), z))
                }

                for i in 0..<pts.count {
                    for j in (i + 1)..<pts.count {
                        let dx = pts[i].0.x - pts[j].0.x
                        let dy = pts[i].0.y - pts[j].0.y
                        let d2 = dx * dx + dy * dy
                        if d2 < 900 {
                            var line = Path()
                            line.move(to: pts[i].0)
                            line.addLine(to: pts[j].0)
                            context.stroke(line, with: .color(Color.cyan.opacity(0.18)), lineWidth: 0.7)
                        }
                    }
                }

                for (pt, z) in pts {
                    let alpha = max(0.2, (z + 1.2) / 2.2)
                    let dotR = CGFloat(1.5 + (z + 1.0) * 1.2)
                    let rect = CGRect(x: pt.x - dotR, y: pt.y - dotR, width: dotR * 2, height: dotR * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.cyan.opacity(alpha)))
                }
            }
            .overlay(
                VStack(spacing: 6) {
                    Text("Æ   T   H   E   R")
                        .font(.system(size: 20, weight: .light, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: .cyan, radius: 10)
                    Text("OS HOME SCREEN LAUNCHER")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                }
            )
        }
    }
}
