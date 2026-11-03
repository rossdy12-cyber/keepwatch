import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Network
import UIKit

struct OmniAppDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let sym: String
    let rgb: (CGFloat, CGFloat, CGFloat)
}

// MARK: - Persistent WKWebView Cache (Prevents White Screens & Reloading When Switching Apps!)
@MainActor
final class WebViewCache {
    static let shared = WebViewCache()
    private var views: [String: WKWebView] = [:]
    private var loadedURLs: [String: String] = [:]

    func webView(for key: String, urlString: String) -> WKWebView {
        if let existing = views[key] {
            if loadedURLs[key] != urlString, let u = URL(string: urlString) {
                loadedURLs[key] = urlString
                existing.load(URLRequest(url: u))
            }
            return existing
        }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: config)
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        w.scrollView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        views[key] = w
        if let u = URL(string: urlString) {
            loadedURLs[key] = urlString
            w.load(URLRequest(url: u))
        }
        return w
    }

    func reload(key: String, urlString: String) {
        guard let u = URL(string: urlString) else { return }
        loadedURLs[key] = urlString
        views[key]?.load(URLRequest(url: u))
    }
}

struct FastCachedWebView: UIViewRepresentable {
    let cacheKey: String
    let urlString: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        let wv = WebViewCache.shared.webView(for: cacheKey, urlString: urlString)
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let wv = WebViewCache.shared.webView(for: cacheKey, urlString: urlString)
        if wv.superview !== uiView {
            wv.removeFromSuperview()
            wv.translatesAutoresizingMaskIntoConstraints = false
            uiView.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.leadingAnchor.constraint(equalTo: uiView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: uiView.trailingAnchor),
                wv.topAnchor.constraint(equalTo: uiView.topAnchor),
                wv.bottomAnchor.constraint(equalTo: uiView.bottomAnchor)
            ])
        }
    }
}

// MARK: - Local Loopback HTTP Server (127.0.0.1:8765) for .mobileconfig & Instant Launch Redirects
final class ClipProfileHTTPServer {
    static let shared = ClipProfileHTTPServer()
    private var listener: NWListener?
    var profileProvider: ((String) -> Data?)?

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            let l = try NWListener(using: params, on: 8765)
            l.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            print("ClipProfileHTTPServer error:", error)
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self,
                  let data = data,
                  let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let path = parts.count > 1 ? parts[1] : "/"

            if path.hasPrefix("/launch/") {
                let appID = path.replacingOccurrences(of: "/launch/", with: "")
                let scheme = appID.hasPrefix("lc-")
                    ? "livecontainer://open?bundle-id=\(appID.replacingOccurrences(of: "lc-", with: ""))"
                    : "omnicontainer://open?app=\(appID)"
                let html = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><script>window.location.replace("\(scheme)");</script></head><body style="background:#060812;color:#fff;font-family:-apple-system,sans-serif;text-align:center;padding-top:40vh;"><a href="\(scheme)" style="color:#00e5ff;font-size:20px;font-weight:bold;">Launching \(appID.uppercased())...</a></body></html>
                """
                let body = Data(html.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(header.utf8)
                payload.append(body)
                conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            let key = path.replacingOccurrences(of: "/clip/", with: "").replacingOccurrences(of: ".mobileconfig", with: "")
            if let body = self.profileProvider?(key) {
                let header = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: application/x-apple-aspen-config",
                    "Content-Disposition: attachment; filename=\"\(key)-v2.mobileconfig\"",
                    "Content-Length: \(body.count)",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                var payload = Data(header.utf8)
                payload.append(body)
                conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
            } else {
                conn.cancel()
            }
        }
    }
}

@MainActor
class OmniWorkspaceStore: ObservableObject {
    let builtInApps: [OmniAppDescriptor] = [
        OmniAppDescriptor(id: "antigravity", title: "Antigravity", subtitle: "3-Node Fleet Command", icon: "cpu.fill", color: .cyan, sym: "AG", rgb: (0.0, 0.9, 1.0)),
        OmniAppDescriptor(id: "aegis", title: "Aegis Browser", subtitle: "Ad-Block + 3-Node Drawer", icon: "shield.lefthalf.filled", color: .blue, sym: "AE", rgb: (0.16, 0.47, 1.0)),
        OmniAppDescriptor(id: "deskswitch", title: "DeskSwitch", subtitle: "Monitor/TV + Steam + Trackpad", icon: "tv.and.mediabox", color: .orange, sym: "DS", rgb: (1.0, 0.58, 0.0)),
        OmniAppDescriptor(id: "sentrycam", title: "SentryCam", subtitle: "Frigate AI CCTV + Tapo PTZ", icon: "video.fill", color: .red, sym: "SC", rgb: (1.0, 0.23, 0.19)),
        OmniAppDescriptor(id: "aniimo", title: "Aniimo Pilot", subtitle: "Live Game Stream & Farm Bot", icon: "gamecontroller.fill", color: .green, sym: "AP", rgb: (0.0, 0.9, 0.46)),
        OmniAppDescriptor(id: "racebolt", title: "Racebolt Ops", subtitle: "SKU Stock Lookup & Audit", icon: "wrench.and.screwdriver.fill", color: .yellow, sym: "RB", rgb: (1.0, 0.8, 0.0)),
        OmniAppDescriptor(id: "photopulse", title: "PhotoPulse", subtitle: "iCloudPD 2FA & Immich Frames", icon: "photo.artframe", color: .pink, sym: "PP", rgb: (1.0, 0.25, 0.5)),
        OmniAppDescriptor(id: "netradar", title: "NetRadar", subtitle: "SpeedTest + Mesh & SSL Audit", icon: "network", color: .teal, sym: "NR", rgb: (0.0, 0.85, 0.95)),
        OmniAppDescriptor(id: "soulseekr", title: "SoulSeekr", subtitle: "slskd + Hearr + Soularr P2P", icon: "waveform.badge.magnifyingglass", color: .purple, sym: "SS", rgb: (0.73, 0.41, 0.78)),
        OmniAppDescriptor(id: "zimadeck", title: "ZimaDeck", subtitle: "Zimaboard + Komga + RustDesk", icon: "server.rack", color: .mint, sym: "ZD", rgb: (0.0, 0.9, 0.7))
    ]

    // Lazy launch: only start apps when opened, and keep their state/WebViews cached!
    @Published var runningAppIDs: [String] = []
    @Published var activeAppID: String = "home"
    @Published var splitScreenEnabled: Bool = false
    @Published var secondaryAppID: String = "sentrycam"
    @Published var statusBanner: String = "Fast WebView Cache Active • Zero Reload Switching"
    @Published var showTopBarInFullScreen: Bool = true

    // Smart Route Selector: Tailscale (100.85.127.42) vs LAN (38.9.96.58)
    @Published var truenasHost: String = "100.85.127.42"
    @Published var routeLabel: String = "Tailscale"

    init() {
        ClipProfileHTTPServer.shared.profileProvider = { [weak self] key in
            guard let self = self else { return nil }
            return self.generateMobileConfigData(forKey: key, host: self.truenasHost)
        }
        ClipProfileHTTPServer.shared.start()
        Task { await detectFastestRoute() }
    }

    func detectFastestRoute() async {
        // Race LAN (38.9.96.58) vs Tailscale (100.85.127.42) with a 0.6s timeout so we never hang!
        if let u = URL(string: "http://38.9.96.58:5000/api/version") {
            var req = URLRequest(url: u)
            req.timeoutInterval = 0.6
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                truenasHost = "38.9.96.58"
                routeLabel = "Direct LAN (Fast)"
                return
            }
        }
        truenasHost = "100.85.127.42"
        routeLabel = "Tailscale"
    }

    func toggleRoute() {
        if truenasHost == "100.85.127.42" {
            truenasHost = "38.9.96.58"
            routeLabel = "Direct LAN"
        } else {
            truenasHost = "100.85.127.42"
            routeLabel = "Tailscale"
        }
    }

    func handleIncomingURL(_ url: URL) {
        let host = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryApp = comps?.queryItems?.first(where: { $0.name == "app" || $0.name == "id" })?.value?.lowercased()
        let target = queryApp ?? host
        if !target.isEmpty && target != "open" {
            launchOrFocus(target)
        }
    }

    func launchOrFocus(_ appID: String) {
        if !runningAppIDs.contains(appID) {
            runningAppIDs.append(appID)
        }
        activeAppID = appID
    }

    func closeRunningApp(_ appID: String) {
        runningAppIDs.removeAll { $0 == appID }
        if activeAppID == appID {
            activeAppID = runningAppIDs.last ?? "home"
        }
    }

    nonisolated func makeIconBase64(sym: String, r: CGFloat, g: CGFloat, b: CGFloat) -> String {
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1.0).setFill()
            ctx.fill(rect)

            let circle = UIBezierPath(ovalIn: rect.insetBy(dx: 14, dy: 14))
            UIColor(red: r, green: g, blue: b, alpha: 0.24).setFill()
            circle.fill()
            UIColor(red: r, green: g, blue: b, alpha: 0.95).setStroke()
            circle.lineWidth = 6
            circle.stroke()

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .heavy),
                .foregroundColor: UIColor(red: r, green: g, blue: b, alpha: 1.0),
                .paragraphStyle: pStyle
            ]
            let textRect = CGRect(x: 0, y: 52, width: 180, height: 80)
            sym.draw(in: textRect, withAttributes: attrs)
        }
        return img.pngData()?.base64EncodedString() ?? ""
    }

    nonisolated func generateMobileConfigData(forKey key: String, host: String) -> Data? {
        // IMPORTANT: iOS com.apple.webclip.managed REQUIRES an http:// or https:// URL to create Home Screen icons!
        // We point each WebClip URL to http://100.85.127.42:8766/launch/<id>, which immediately bounces to omnicontainer://open?app=<id>!
        let baseBounce = "http://\(host):8766/launch"
        let apps: [(id: String, title: String, sym: String, url: String, rgb: (CGFloat, CGFloat, CGFloat))] = [
            ("antigravity", "Antigravity", "AG", "\(baseBounce)/antigravity", (0.0, 0.9, 1.0)),
            ("aegis", "Aegis Browser", "AE", "\(baseBounce)/aegis", (0.16, 0.47, 1.0)),
            ("deskswitch", "DeskSwitch", "DS", "\(baseBounce)/deskswitch", (1.0, 0.58, 0.0)),
            ("sentrycam", "SentryCam", "SC", "\(baseBounce)/sentrycam", (1.0, 0.23, 0.19)),
            ("aniimo", "Aniimo Pilot", "AP", "\(baseBounce)/aniimo", (0.0, 0.9, 0.46)),
            ("racebolt", "Racebolt Ops", "RB", "\(baseBounce)/racebolt", (1.0, 0.8, 0.0)),
            ("photopulse", "PhotoPulse", "PP", "\(baseBounce)/photopulse", (1.0, 0.25, 0.5)),
            ("netradar", "NetRadar", "NR", "\(baseBounce)/netradar", (0.0, 0.85, 0.95)),
            ("soulseekr", "SoulSeekr", "SS", "\(baseBounce)/soulseekr", (0.73, 0.41, 0.78)),
            ("zimadeck", "ZimaDeck", "ZD", "\(baseBounce)/zimadeck", (0.0, 0.9, 0.7))
        ]

        let selected: [(id: String, title: String, sym: String, url: String, rgb: (CGFloat, CGFloat, CGFloat))]
        if key == "all" {
            selected = apps
        } else if key.hasPrefix("lc-") {
            let bid = key.replacingOccurrences(of: "lc-", with: "")
            let shortTitle = bid.components(separatedBy: ".").last?.capitalized ?? bid
            let sym = String(shortTitle.prefix(2)).uppercased()
            selected = [(bid, shortTitle, sym, "\(baseBounce)/lc-\(bid)", (1.0, 0.58, 0.0))]
        } else if let found = apps.first(where: { $0.id == key }) {
            selected = [found]
        } else {
            selected = [(key, key.capitalized, "OC", "\(baseBounce)/\(key)", (0.0, 0.9, 1.0))]
        }

        var payloadsXML = ""
        for item in selected {
            let uuid = UUID().uuidString
            let iconB64 = makeIconBase64(sym: item.sym, r: item.rgb.0, g: item.rgb.1, b: item.rgb.2)
            payloadsXML += """
            <dict>
                <key>FullScreen</key>
                <true/>
                <key>Icon</key>
                <data>\(iconB64)</data>
                <key>IgnoreManifestScope</key>
                <true/>
                <key>IsRemovable</key>
                <true/>
                <key>Label</key>
                <string>\(item.title)</string>
                <key>PayloadDescription</key>
                <string>Home Screen ClipApp Launcher for \(item.title)</string>
                <key>PayloadDisplayName</key>
                <string>\(item.title)</string>
                <key>PayloadIdentifier</key>
                <string>com.ross.omnicontainer.webclip.v2.\(item.id)</string>
                <key>PayloadType</key>
                <string>com.apple.webclip.managed</string>
                <key>PayloadUUID</key>
                <string>\(uuid)</string>
                <key>PayloadVersion</key>
                <integer>1</integer>
                <key>Precomposed</key>
                <true/>
                <key>URL</key>
                <string>\(item.url)</string>
            </dict>
            """
        }

        let rootUUID = UUID().uuidString
        let displayTitle = (key == "all") ? "OmniContainer 10 Home Screen ClipApps (v2)" : "\(selected.first?.title ?? key) Home Screen ClipApp"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                \(payloadsXML)
            </array>
            <key>PayloadDescription</key>
            <string>Adds 10 custom Home Screen icons that launch straight into each app inside OmniContainer without closing your other running apps.</string>
            <key>PayloadDisplayName</key>
            <string>\(displayTitle)</string>
            <key>PayloadIdentifier</key>
            <string>com.ross.omnicontainer.profile.v2.\(key)</string>
            <key>PayloadOrganization</key>
            <string>Ross Homelab</string>
            <key>PayloadRemovalDisallowed</key>
            <false/>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>\(rootUUID)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    func installClipAppToHomeScreen(key: String) {
        if let u = URL(string: "http://127.0.0.1:8765/clip/\(key).mobileconfig") {
            UIApplication.shared.open(u)
        }
    }
}

@main
struct OmniContainerApp: App {
    @StateObject private var workspace = OmniWorkspaceStore()
    var body: some Scene {
        WindowGroup {
            OmniRootContainerView()
                .environmentObject(workspace)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    workspace.handleIncomingURL(url)
                }
        }
    }
}

struct OmniRootContainerView: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            omniTopDockBar

            GeometryReader { geo in
                ZStack {
                    if workspace.activeAppID == "home" {
                        OmniSpringBoardView()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else if workspace.splitScreenEnabled {
                        VStack(spacing: 0) {
                            EmbeddedLiveAppHost(appID: workspace.activeAppID)
                                .frame(width: geo.size.width, height: geo.size.height * 0.5)
                            Divider().background(Color.cyan)
                            EmbeddedLiveAppHost(appID: workspace.secondaryAppID)
                                .frame(width: geo.size.width, height: geo.size.height * 0.5)
                        }
                    } else {
                        EmbeddedLiveAppHost(appID: workspace.activeAppID)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.08).ignoresSafeArea())
    }

    private var omniTopDockBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    workspace.activeAppID = "home"
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.3x3.fill")
                        Text("Apps")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(workspace.activeAppID == "home" ? Color.cyan : Color.white.opacity(0.1))
                    .foregroundColor(workspace.activeAppID == "home" ? .black : .white)
                    .cornerRadius(8)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.runningAppIDs, id: \.self) { id in
                            if let app = workspace.builtInApps.first(where: { $0.id == id }) {
                                let isActive = (workspace.activeAppID == id)
                                HStack(spacing: 4) {
                                    Button {
                                        workspace.launchOrFocus(id)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 6, height: 6)
                                            Text(app.title)
                                                .font(.caption2.bold())
                                                .foregroundColor(.white)
                                        }
                                    }
                                    Button {
                                        workspace.closeRunningApp(id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(isActive ? app.color.opacity(0.32) : Color.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isActive ? app.color : Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .cornerRadius(8)
                            }
                        }
                    }
                }

                Button {
                    workspace.toggleRoute()
                } label: {
                    Text(workspace.routeLabel)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                }

                Button {
                    workspace.splitScreenEnabled.toggle()
                } label: {
                    Image(systemName: workspace.splitScreenEnabled ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .font(.caption.bold())
                        .padding(6)
                        .background(workspace.splitScreenEnabled ? Color.orange : Color.white.opacity(0.1))
                        .foregroundColor(workspace.splitScreenEnabled ? .black : .white)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            if workspace.splitScreenEnabled && workspace.activeAppID != "home" {
                HStack(spacing: 6) {
                    Text("Bottom Split:")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Picker("Bottom App", selection: $workspace.secondaryAppID) {
                        ForEach(workspace.builtInApps) { a in
                            Text(a.title).tag(a.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.75))
    }
}

struct OmniSpringBoardView: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore
    @State private var customBundleID: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "apps.iphone.badge.plus")
                            .font(.title2)
                            .foregroundColor(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Home Screen ClipApp Installer (Fixed v2)")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                            Text("Uses HTTP WebClip bounce URLs (`http://\(workspace.truenasHost):8766/launch/...`) so iOS creates all 10 icons on your Home Screen!")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }

                    Button {
                        workspace.installClipAppToHomeScreen(key: "all")
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down.on.square.fill")
                            Text("Install All 10 Home Screen ClipApps (v2)")
                                .font(.subheadline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.black)
                        .cornerRadius(12)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                .cornerRadius(14)

                HStack {
                    Text("Apps (Instant WebView Cache)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Text("Active Route: \(workspace.truenasHost)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.green)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(workspace.builtInApps) { app in
                        let isRunning = workspace.runningAppIDs.contains(app.id)
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                workspace.launchOrFocus(app.id)
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack(alignment: .topTrailing) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(app.color.opacity(0.22))
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Image(systemName: app.icon)
                                                    .font(.title3)
                                                    .foregroundColor(app.color)
                                            )
                                        if isRunning {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 10, height: 10)
                                                .offset(x: 3, y: -3)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.title)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(app.subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }

                            HStack(spacing: 6) {
                                Button {
                                    workspace.launchOrFocus(app.id)
                                } label: {
                                    Text(isRunning ? "Switch To" : "Open")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(app.color.opacity(0.25))
                                        .foregroundColor(app.color)
                                        .cornerRadius(7)
                                }

                                Button {
                                    workspace.installClipAppToHomeScreen(key: app.id)
                                } label: {
                                    Text("+ Clip")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.1))
                                        .foregroundColor(.white)
                                        .cornerRadius(7)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isRunning ? Color.green.opacity(0.5) : app.color.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(14)
                    }
                }
            }
            .padding()
        }
    }
}

struct EmbeddedLiveAppHost: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore
    let appID: String

    var body: some View {
        switch appID {
        case "antigravity":
            MiniAntigravityModule()
        case "aegis":
            MiniAegisModule()
        case "deskswitch":
            MiniDeskSwitchModule()
        case "sentrycam":
            MiniSentryCamModule(host: workspace.truenasHost)
        case "aniimo":
            MiniAniimoModule()
        case "racebolt":
            FastCachedWebView(cacheKey: "racebolt", urlString: "https://raceboltuk.com")
        case "photopulse":
            MiniPhotoPulseModule(host: workspace.truenasHost)
        case "netradar":
            MiniNetRadarModule(host: workspace.truenasHost)
        case "soulseekr":
            MiniSoulSeekrModule(host: workspace.truenasHost)
        case "zimadeck":
            MiniZimaDeckModule(host: workspace.truenasHost)
        default:
            FastCachedWebView(cacheKey: "home-dash", urlString: "http://\(workspace.truenasHost):3000")
        }
    }
}

// MARK: - 1. SentryCam Module (Fixed Port 5000 + All 3 Cameras: tapo_c200, bike_camera, doorbell + PTZ!)
struct MiniSentryCamModule: View {
    let host: String
    @State private var selectedCam = "tapo_c200"
    @State private var viewMode = 0 // 0 = All 3 Cameras Grid, 1 = Single Camera + PTZ, 2 = Frigate WebUI
    @State private var tick = Int(Date().timeIntervalSince1970)
    @State private var status = "Connected to Frigate NVR (:5000)"

    let cameras = [
        ("tapo_c200", "Tapo C200 (Garden/Porch)"),
        ("bike_camera", "Bike Camera"),
        ("doorbell", "Front Doorbell")
    ]

    let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $viewMode) {
                Text("All 3 Cameras").tag(0)
                Text("PTZ & Single").tag(1)
                Text("Frigate UI").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if viewMode == 0 {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(cameras, id: \.0) { cam in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                    Text(cam.1).font(.caption.bold()).foregroundColor(.white)
                                    Spacer()
                                    Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.red)
                                }
                                AsyncImage(url: URL(string: "http://\(host):5000/api/\(cam.0)/latest.jpg?h=480&t=\(tick)")) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFit()
                                    } else {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.white.opacity(0.06))
                                            .frame(height: 180)
                                            .overlay(ProgressView().tint(.red))
                                    }
                                }
                                .cornerRadius(10)
                                .onTapGesture {
                                    selectedCam = cam.0
                                    viewMode = 1
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                        }
                    }
                    .padding(12)
                }
            } else if viewMode == 1 {
                ScrollView {
                    VStack(spacing: 12) {
                        Picker("Camera", selection: $selectedCam) {
                            ForEach(cameras, id: \.0) { c in
                                Text(c.1).tag(c.0)
                            }
                        }
                        .pickerStyle(.segmented)

                        AsyncImage(url: URL(string: "http://\(host):5000/api/\(selectedCam)/latest.jpg?h=720&t=\(tick)")) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 220)
                                    .overlay(ProgressView().tint(.red))
                            }
                        }
                        .cornerRadius(12)

                        Text(status).font(.caption2).foregroundColor(.orange)

                        HStack(spacing: 12) {
                            ptzBtn("Start Patrol", cmd: "sudo docker start tapo-patrol")
                            ptzBtn("Stop Patrol", cmd: "sudo docker stop tapo-patrol")
                            Button("Refresh") { tick = Int(Date().timeIntervalSince1970) }
                                .font(.caption.bold())
                                .padding(10)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    .padding(12)
                }
            } else {
                FastCachedWebView(cacheKey: "frigate-ui", urlString: "http://\(host):5000")
            }
        }
        .onReceive(timer) { _ in
            if viewMode != 2 {
                tick = Int(Date().timeIntervalSince1970)
            }
        }
    }

    func ptzBtn(_ title: String, cmd: String) -> some View {
        Button(title) {
            Task {
                guard let u = URL(string: "http://\(host):9092/api/antigravity/exec") else { return }
                var req = URLRequest(url: u)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
                _ = try? await URLSession.shared.data(for: req)
                status = "Executed: \(title)"
            }
        }
        .font(.caption.bold())
        .padding(10)
        .background(Color.white.opacity(0.1))
        .foregroundColor(.white)
        .cornerRadius(8)
    }
}

// MARK: - 2. NetRadar Module (Native Instant SpeedTest + OpenSpeedTest :30116 + Mesh Probe)
struct MiniNetRadarModule: View {
    let host: String
    @State private var tab = 0
    @State private var pingMs: String = "--"
    @State private var downMbps: String = "--"
    @State private var isTesting = false
    @State private var logText = "Tap 'Run Native SpeedTest' for instant TrueNAS bandwidth & latency measurement."

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $tab) {
                Text("Native SpeedTest").tag(0)
                Text("OpenSpeedTest (:30116)").tag(1)
                Text("NPM (:30020)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 14) {
                            VStack(spacing: 4) {
                                Text("PING LATENCY")
                                    .font(.caption2.bold()).foregroundColor(.gray)
                                Text("\(pingMs) ms")
                                    .font(.title.bold().monospacedDigit()).foregroundColor(.cyan)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(14)

                            VStack(spacing: 4) {
                                Text("DOWNLOAD SPEED")
                                    .font(.caption2.bold()).foregroundColor(.gray)
                                Text("\(downMbps) Mbps")
                                    .font(.title.bold().monospacedDigit()).foregroundColor(.green)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(14)
                        }

                        Button {
                            Task { await runNativeBenchmark() }
                        } label: {
                            HStack {
                                if isTesting { ProgressView().tint(.black) }
                                Image(systemName: "speedometer")
                                Text(isTesting ? "Measuring Bandwidth..." : "Run Native SpeedTest to TrueNAS (\(host))")
                                    .font(.subheadline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(12)
                        }
                        .disabled(isTesting)

                        Text(logText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(10)
                    }
                    .padding()
                }
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "ost-30116", urlString: "http://\(host):30116")
            } else {
                FastCachedWebView(cacheKey: "npm-30020", urlString: "http://\(host):30020")
            }
        }
    }

    func runNativeBenchmark() async {
        isTesting = true
        defer { isTesting = false }
        // 1. Measure Ping
        let t0 = Date()
        if let u = URL(string: "http://\(host):5000/api/version") {
            _ = try? await URLSession.shared.data(from: u)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            pingMs = "\(ms)"
        }
        // 2. Measure Throughput by pulling 8 camera frames / payload from TrueNAS
        let tStart = Date()
        var totalBytes = 0
        for i in 0..<6 {
            if let u = URL(string: "http://\(host):5000/api/tapo_c200/latest.jpg?h=1080&b=\(i)_\(Int.random(in: 1...99999))"),
               let (d, _) = try? await URLSession.shared.data(from: u) {
                totalBytes += d.count
            }
        }
        let elapsed = max(Date().timeIntervalSince(tStart), 0.05)
        let mbps = (Double(totalBytes * 8) / 1_000_000.0) / elapsed
        downMbps = String(format: "%.1f", mbps)
        logText = "Target: \(host)\nTransferred: \(totalBytes / 1024) KB in \(String(format: "%.2f", elapsed))s\nMeasured Speed: \(downMbps) Mbps • Ping: \(pingMs) ms"
    }
}

// MARK: - 3. PhotoPulse Module (Cached Immich WebView + Instant 2FA)
struct MiniPhotoPulseModule: View {
    let host: String
    @State private var tab = 0
    @State private var code = ""
    @State private var container = "icloudpd"
    @State private var status = "Immich & iCloudPD Ready"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $tab) {
                Text("Immich (:30041)").tag(0)
                Text("ImmichFrame (:9180)").tag(1)
                Text("Apple 2FA").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "immich-main", urlString: "http://\(host):30041")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "immich-frame", urlString: "http://\(host):9180")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(status).font(.caption).foregroundColor(.pink)
                        Picker("Stream", selection: $container) {
                            Text("Personal").tag("icloudpd")
                            Text("Shared").tag("icloudpd-shared")
                            Text("Hidden").tag("icloudpd-hidden")
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            TextField("6-Digit Apple 2FA Code", text: $code)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            Button("Submit 2FA") {
                                let c = code; code = ""
                                Task { await send2FA(c) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pink)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    func send2FA(_ c: String) async {
        guard let u = URL(string: "http://\(host):9092/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "echo '\(c)' | sudo docker attach --sig-proxy=false \(container) 2>&1"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        _ = try? await URLSession.shared.data(for: req)
        status = "Submitted 2FA code \(c) to \(container)"
    }
}

struct MiniSoulSeekrModule: View {
    let host: String
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Service", selection: $tab) {
                Text("Hearr (:5070)").tag(0)
                Text("slskd (:5030)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "hearr-5070", urlString: "http://\(host):5070")
            } else {
                FastCachedWebView(cacheKey: "slskd-5030", urlString: "http://\(host):5030")
            }
        }
    }
}

struct MiniZimaDeckModule: View {
    let host: String
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Service", selection: $tab) {
                Text("Komga (:30048)").tag(0)
                Text("Zima Portainer").tag(1)
                Text("Zima Immich").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "komga-30048", urlString: "http://\(host):30048")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "zima-port", urlString: "http://100.82.255.29:9000")
            } else {
                FastCachedWebView(cacheKey: "zima-immich", urlString: "http://100.82.255.29:2283")
            }
        }
    }
}

struct MiniAntigravityModule: View {
    @State private var selectedNode = "100.102.4.54:9090"
    @State private var prompt = ""
    @State private var output = "Connected to 3-Node Antigravity Fleet (#1 Windows, #2 Bazzite, #3 TrueNAS)."
    @State private var screenTick = 0

    let nodes = [
        ("Win #1", "100.102.4.54:9090"),
        ("Bazzite #2", "100.79.246.119:9091"),
        ("TrueNAS #3", "100.85.127.42:9092")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Node", selection: $selectedNode) {
                    ForEach(nodes, id: \.1) { n in
                        Text(n.0).tag(n.1)
                    }
                }
                .pickerStyle(.segmented)

                AsyncImage(url: URL(string: "http://\(selectedNode)/api/antigravity/screen?t=\(screenTick)")) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 160)
                        .overlay(Text("Tap to refresh live screen (\(selectedNode))").font(.caption).foregroundColor(.gray))
                }
                .frame(maxHeight: 200)
                .cornerRadius(10)
                .onTapGesture { screenTick += 1 }

                HStack {
                    TextField("Message or shell command...", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                    Button("Chat") {
                        let p = prompt; prompt = ""
                        Task { await sendChat(p) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Exec") {
                        let p = prompt; prompt = ""
                        Task { await sendExec(p) }
                    }
                    .buttonStyle(.bordered)
                }

                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
            }
            .padding(12)
        }
    }

    func sendChat(_ text: String) async {
        guard let u = URL(string: "http://\(selectedNode)/api/antigravity/chat") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["message": text])
        if let (d, _) = try? await URLSession.shared.data(for: req) {
            output = String(data: d, encoding: .utf8) ?? "Sent"
        }
    }

    func sendExec(_ cmd: String) async {
        guard let u = URL(string: "http://\(selectedNode)/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        if let (d, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            output = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? "Done"
        }
    }
}

struct MiniAegisModule: View {
    @State private var urlInput = "https://duckduckgo.com"
    @State private var activeURL = "https://duckduckgo.com"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shield.fill").foregroundColor(.cyan)
                TextField("Search or URL", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { navigate() }
                Button("Go") { navigate() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(8)
            .background(Color.black.opacity(0.6))

            FastCachedWebView(cacheKey: "aegis-main", urlString: activeURL)
        }
    }

    func navigate() {
        var s = urlInput.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") {
            if s.contains(".") && !s.contains(" ") { s = "https://" + s }
            else { s = "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") }
        }
        activeURL = s
    }
}

struct MiniDeskSwitchModule: View {
    @State private var status = "Ready to switch Windows / Bazzite displays & Steam"
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(status).font(.caption).foregroundColor(.orange)
                HStack(spacing: 10) {
                    btn("Monitor Only", flag: "/internal", color: .cyan)
                    btn("TV Only", flag: "/external", color: .orange)
                    btn("Extend All", flag: "/extend", color: .purple)
                }
                HStack(spacing: 10) {
                    cmdBtn("Steam Big Picture", cmd: "cmd.exe /c start steam://open/bigpicture", color: .blue)
                    cmdBtn("Jellyfin TV", cmd: "cmd.exe /c start https://jellyfin.nas-server.co.uk", color: .pink)
                }
                HStack(spacing: 10) {
                    cmdBtn("Sleep PC", cmd: "rundll32.exe powrprof.dll,SetSuspendState 0,1,0", color: .indigo)
                    cmdBtn("Lock PC", cmd: "rundll32.exe user32.dll,LockWorkStation", color: .yellow)
                }
            }
            .padding()
        }
    }

    func btn(_ label: String, flag: String, color: Color) -> some View {
        Button(label) {
            Task { await execWin("DisplaySwitch.exe \(flag)") }
        }
        .font(.caption.bold())
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.22))
        .foregroundColor(color)
        .cornerRadius(10)
    }

    func cmdBtn(_ label: String, cmd: String, color: Color) -> some View {
        Button(label) {
            Task { await execWin(cmd) }
        }
        .font(.caption.bold())
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.22))
        .foregroundColor(color)
        .cornerRadius(10)
    }

    func execWin(_ c: String) async {
        guard let u = URL(string: "http://100.102.4.54:9090/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": c])
        _ = try? await URLSession.shared.data(for: req)
        status = "Executed: \(c)"
    }
}

struct MiniAniimoModule: View {
    @State private var tick = 0
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                AsyncImage(url: URL(string: "http://100.102.4.54:9090/api/antigravity/screen?t=\(tick)")) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)).frame(height: 180)
                }
                .cornerRadius(10)
                .onTapGesture { tick += 1 }

                HStack {
                    Button("Refresh Game Screen") { tick += 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
}
