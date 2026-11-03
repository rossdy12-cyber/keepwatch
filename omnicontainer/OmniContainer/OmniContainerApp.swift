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
    let hexColor: String
    let symbolText: String
    let bundleID: String
}

struct ImportedIPAItem: Identifiable, Codable {
    var id: String = UUID().uuidString
    let fileName: String
    let bundleName: String
    let bundleID: String
    let version: String
    let executableName: String
    let fileSizeMB: String
    let importedAt: Date
    var targetScheme: String // "omnicontainer" or "livecontainer"
}

// MARK: - Local Loopback HTTP Server (127.0.0.1:8765) to Install .mobileconfig Home Screen ClipApps directly in iOS Safari!
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
            let key = path.replacingOccurrences(of: "/clip/", with: "").replacingOccurrences(of: ".mobileconfig", with: "")

            if let body = self.profileProvider?(key) {
                let header = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: application/x-apple-aspen-config",
                    "Content-Disposition: attachment; filename=\"\(key).mobileconfig\"",
                    "Content-Length: \(body.count)",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                var payload = Data(header.utf8)
                payload.append(body)
                conn.send(content: payload, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } else {
                let msg = Data("Profile not found".utf8)
                let header = "HTTP/1.1 404 Not Found\r\nContent-Length: \(msg.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(header.utf8)
                payload.append(msg)
                conn.send(content: payload, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }
}

@MainActor
class OmniWorkspaceStore: ObservableObject {
    let builtInApps: [OmniAppDescriptor] = [
        OmniAppDescriptor(id: "antigravity", title: "Antigravity", subtitle: "3-Node Fleet Command", icon: "cpu.fill", color: .cyan, hexColor: "#00E5FF", symbolText: "AG", bundleID: "com.ross.antigravity"),
        OmniAppDescriptor(id: "aegis", title: "Aegis Browser", subtitle: "Ad-Block + 3-Node Drawer", icon: "shield.lefthalf.filled", color: .blue, hexColor: "#2979FF", symbolText: "AE", bundleID: "com.ross.aegismobile"),
        OmniAppDescriptor(id: "deskswitch", title: "DeskSwitch", subtitle: "Monitor/TV + Steam + Trackpad", icon: "tv.and.mediabox", color: .orange, hexColor: "#FF9500", symbolText: "DS", bundleID: "com.ross.deskswitch"),
        OmniAppDescriptor(id: "sentrycam", title: "SentryCam", subtitle: "Frigate AI CCTV + Tapo PTZ", icon: "video.fill", color: .red, hexColor: "#FF3B30", symbolText: "SC", bundleID: "com.ross.sentrycam"),
        OmniAppDescriptor(id: "aniimo", title: "Aniimo Pilot", subtitle: "Live Game Stream & Farm Bot", icon: "gamecontroller.fill", color: .green, hexColor: "#00E676", symbolText: "AP", bundleID: "com.ross.aniimopilot"),
        OmniAppDescriptor(id: "racebolt", title: "Racebolt Ops", subtitle: "SKU Stock Lookup & Audit", icon: "wrench.and.screwdriver.fill", color: .yellow, hexColor: "#FFCC00", symbolText: "RB", bundleID: "com.ross.raceboltops"),
        OmniAppDescriptor(id: "photopulse", title: "PhotoPulse", subtitle: "iCloudPD 2FA & Immich Frames", icon: "photo.artframe", color: .pink, hexColor: "#FF4081", symbolText: "PP", bundleID: "com.ross.photopulse"),
        OmniAppDescriptor(id: "netradar", title: "NetRadar", subtitle: "Tailscale Mesh & SSL Audit", icon: "network", color: .teal, hexColor: "#00E5FF", symbolText: "NR", bundleID: "com.ross.netradar"),
        OmniAppDescriptor(id: "soulseekr", title: "SoulSeekr", subtitle: "slskd + Hearr + Soularr P2P", icon: "waveform.badge.magnifyingglass", color: .purple, hexColor: "#BA68C8", symbolText: "SS", bundleID: "com.ross.soulseekr"),
        OmniAppDescriptor(id: "zimadeck", title: "ZimaDeck", subtitle: "Zimaboard + Komga + RustDesk", icon: "server.rack", color: .mint, hexColor: "#00E6B4", symbolText: "ZD", bundleID: "com.ross.zimadeck")
    ]

    // Pre-keep all 10 apps warm or launch on demand; once in runningAppIDs, they NEVER close when switching!
    @Published var runningAppIDs: [String] = ["antigravity", "deskswitch", "aegis", "sentrycam"]
    @Published var activeAppID: String = "home"
    @Published var splitScreenEnabled: Bool = false
    @Published var secondaryAppID: String = "sentrycam"
    @Published var importedIPAs: [ImportedIPAItem] = []
    @Published var statusBanner: String = "Tap any ClipApp on your iPhone Home Screen to jump straight into that app!"
    @Published var showTopBarInFullScreen: Bool = true

    private let importedKey = "omnicontainer.imported.ipas.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: importedKey),
           let decoded = try? JSONDecoder().decode([ImportedIPAItem].self, from: data) {
            importedIPAs = decoded
        }
        ClipProfileHTTPServer.shared.profileProvider = { [weak self] key in
            guard let self = self else { return nil }
            return self.generateMobileConfigData(forKey: key)
        }
        ClipProfileHTTPServer.shared.start()
    }

    func handleIncomingURL(_ url: URL) {
        // Supports:
        // omnicontainer://open?app=deskswitch
        // omnicontainer://deskswitch
        let host = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryApp = comps?.queryItems?.first(where: { $0.name == "app" || $0.name == "id" })?.value?.lowercased()
        let target = queryApp ?? host
        if !target.isEmpty && target != "open" {
            launchOrFocus(target)
            statusBanner = "Direct-launched \(target.uppercased()) from Home Screen ClipApp!"
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

    func saveImported() {
        if let data = try? JSONEncoder().encode(importedIPAs) {
            UserDefaults.standard.set(data, forKey: importedKey)
        }
    }

    func importIPAFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ipaDir = docs.appendingPathComponent("ImportedIPAs", isDirectory: true)
        try? fm.createDirectory(at: ipaDir, withIntermediateDirectories: true)

        let fileName = url.lastPathComponent
        let dest = ipaDir.appendingPathComponent(fileName)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: url, to: dest)
            let attrs = try? fm.attributesOfItem(atPath: dest.path)
            let bytes = (attrs?[.size] as? Int64) ?? 0
            let mb = String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
            let cleanName = fileName.replacingOccurrences(of: ".ipa", with: "")
            let item = ImportedIPAItem(
                fileName: fileName,
                bundleName: cleanName,
                bundleID: "com.ross.\(cleanName.lowercased())",
                version: "1.0",
                executableName: cleanName,
                fileSizeMB: mb,
                importedAt: Date(),
                targetScheme: "omnicontainer"
            )
            importedIPAs.insert(item, at: 0)
            saveImported()
            statusBanner = "Imported \(fileName) (\(mb))!"
        } catch {
            statusBanner = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Home Screen ClipApp (.mobileconfig) Generator
    func renderClipIconPNG(symbolText: String, hexColor: String) -> String {
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1.0).setFill()
            ctx.fill(rect)

            let circle = UIBezierPath(ovalIn: rect.insetBy(dx: 16, dy: 16))
            UIColor.cyan.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 4
            circle.stroke()

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: pStyle
            ]
            let textRect = CGRect(x: 0, y: 50, width: 180, height: 80)
            symbolText.draw(in: textRect, withAttributes: attrs)
        }
        return img.pngData()?.base64EncodedString() ?? ""
    }

    nonisolated func makeIconBase64(sym: String, r: CGFloat, g: CGFloat, b: CGFloat) -> String {
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1.0).setFill()
            ctx.fill(rect)

            let circle = UIBezierPath(ovalIn: rect.insetBy(dx: 14, dy: 14))
            UIColor(red: r, green: g, blue: b, alpha: 0.22).setFill()
            circle.fill()
            UIColor(red: r, green: g, blue: b, alpha: 0.9).setStroke()
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

    nonisolated func generateMobileConfigData(forKey key: String) -> Data? {
        // Build either a single WebClip or the All-10 ClipApps bundle!
        let apps: [(id: String, title: String, sym: String, url: String, rgb: (CGFloat, CGFloat, CGFloat))] = [
            ("antigravity", "Antigravity", "AG", "omnicontainer://open?app=antigravity", (0.0, 0.9, 1.0)),
            ("aegis", "Aegis Browser", "AE", "omnicontainer://open?app=aegis", (0.16, 0.47, 1.0)),
            ("deskswitch", "DeskSwitch", "DS", "omnicontainer://open?app=deskswitch", (1.0, 0.58, 0.0)),
            ("sentrycam", "SentryCam", "SC", "omnicontainer://open?app=sentrycam", (1.0, 0.23, 0.19)),
            ("aniimo", "Aniimo Pilot", "AP", "omnicontainer://open?app=aniimo", (0.0, 0.9, 0.46)),
            ("racebolt", "Racebolt Ops", "RB", "omnicontainer://open?app=racebolt", (1.0, 0.8, 0.0)),
            ("photopulse", "PhotoPulse", "PP", "omnicontainer://open?app=photopulse", (1.0, 0.25, 0.5)),
            ("netradar", "NetRadar", "NR", "omnicontainer://open?app=netradar", (0.0, 0.85, 0.95)),
            ("soulseekr", "SoulSeekr", "SS", "omnicontainer://open?app=soulseekr", (0.73, 0.41, 0.78)),
            ("zimadeck", "ZimaDeck", "ZD", "omnicontainer://open?app=zimadeck", (0.0, 0.9, 0.7))
        ]

        let selected: [(id: String, title: String, sym: String, url: String, rgb: (CGFloat, CGFloat, CGFloat))]
        if key == "all" {
            selected = apps
        } else if key.hasPrefix("lc-") {
            let bid = key.replacingOccurrences(of: "lc-", with: "")
            let shortTitle = bid.components(separatedBy: ".").last?.capitalized ?? bid
            let sym = String(shortTitle.prefix(2)).uppercased()
            selected = [(bid, shortTitle, sym, "livecontainer://open?bundle-id=\(bid)", (1.0, 0.58, 0.0))]
        } else if let found = apps.first(where: { $0.id == key }) {
            selected = [found]
        } else {
            selected = [(key, key.capitalized, "OC", "omnicontainer://open?app=\(key)", (0.0, 0.9, 1.0))]
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
                <string>Direct Home Screen ClipApp Launcher for \(item.title)</string>
                <key>PayloadDisplayName</key>
                <string>\(item.title) ClipApp</string>
                <key>PayloadIdentifier</key>
                <string>com.ross.omnicontainer.webclip.\(item.id)</string>
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
        let displayTitle = (key == "all") ? "OmniContainer All 10 Home Screen ClipApps" : "\(selected.first?.title ?? key) Home Screen ClipApp"
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
            <string>Adds instant-launch ClipApp icons to your iPhone Home Screen that open straight into each app inside OmniContainer without closing your other running apps.</string>
            <key>PayloadDisplayName</key>
            <string>\(displayTitle)</string>
            <key>PayloadIdentifier</key>
            <string>com.ross.omnicontainer.profile.\(key)</string>
            <key>PayloadOrganization</key>
            <string>Ross Homelab &amp; Antigravity</string>
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
            statusBanner = "Opened ClipApp installer in Safari — tap Allow, then Install in Settings!"
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
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            if workspace.showTopBarInFullScreen || workspace.activeAppID == "home" {
                omniTopDockBar
            } else {
                // Ultra-slim floating pill when inside a ClipApp so it feels 100% like a standalone native app!
                HStack {
                    Button {
                        workspace.activeAppID = "home"
                    } label: {
                        Label("All Apps (\(workspace.runningAppIDs.count) Running)", systemImage: "square.grid.2x2.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                    Spacer()
                    Text(workspace.activeAppID.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Button {
                        workspace.showTopBarInFullScreen = true
                    } label: {
                        Image(systemName: "Dock.rectangle")
                            .font(.caption2)
                            .foregroundColor(.white)
                        Text("Show Dock")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.85))
            }

            GeometryReader { geo in
                ZStack {
                    OmniSpringBoardView(showFileImporter: $showFileImporter)
                        .opacity(workspace.activeAppID == "home" ? 1 : 0)
                        .allowsHitTesting(workspace.activeAppID == "home")

                    // Every running app stays alive in ZStack memory so switching via Home Screen ClipApps is 0.0s!
                    ForEach(workspace.builtInApps) { app in
                        if workspace.runningAppIDs.contains(app.id) {
                            let isPrimary = (workspace.activeAppID == app.id)
                            let isSecondary = (workspace.splitScreenEnabled && workspace.secondaryAppID == app.id && workspace.activeAppID != "home")

                            if isPrimary && !workspace.splitScreenEnabled {
                                EmbeddedLiveAppHost(appID: app.id)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            } else if workspace.splitScreenEnabled && workspace.activeAppID != "home" && (isPrimary || isSecondary) {
                                VStack(spacing: 0) {
                                    if isPrimary {
                                        EmbeddedLiveAppHost(appID: workspace.activeAppID)
                                            .frame(width: geo.size.width, height: geo.size.height * 0.5)
                                        Divider().background(Color.cyan)
                                        EmbeddedLiveAppHost(appID: workspace.secondaryAppID)
                                            .frame(width: geo.size.width, height: geo.size.height * 0.5)
                                    }
                                }
                            } else {
                                EmbeddedLiveAppHost(appID: app.id)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .opacity(0.0001)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.08).ignoresSafeArea())
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType.data, UTType.archive, UTType.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                workspace.importIPAFile(from: first)
            }
        }
    }

    private var omniTopDockBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    workspace.activeAppID = "home"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.3x3.fill")
                        Text("ClipApps")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
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
                                HStack(spacing: 5) {
                                    Button {
                                        workspace.launchOrFocus(id)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 6, height: 6)
                                            Image(systemName: app.icon)
                                                .font(.caption2)
                                                .foregroundColor(app.color)
                                            Text(app.title)
                                                .font(.caption2.bold())
                                                .foregroundColor(.white)
                                        }
                                    }
                                    Button {
                                        workspace.closeRunningApp(id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.horizontal, 9)
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
                    workspace.splitScreenEnabled.toggle()
                } label: {
                    Image(systemName: workspace.splitScreenEnabled ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .font(.caption.bold())
                        .padding(7)
                        .background(workspace.splitScreenEnabled ? Color.orange : Color.white.opacity(0.1))
                        .foregroundColor(workspace.splitScreenEnabled ? .black : .white)
                        .cornerRadius(8)
                }

                if workspace.activeAppID != "home" {
                    Button {
                        workspace.showTopBarInFullScreen = false
                    } label: {
                        Image(systemName: "chevron.up.circle.fill")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            if workspace.splitScreenEnabled && workspace.activeAppID != "home" {
                HStack(spacing: 6) {
                    Text("Bottom Split App:")
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
        .background(Color.black.opacity(0.65))
    }
}

struct OmniSpringBoardView: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore
    @Binding var showFileImporter: Bool
    @State private var customBundleID: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1-Tap Install All 10 Home Screen ClipApps Banner
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "apps.iphone.badge.plus")
                            .font(.title2)
                            .foregroundColor(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Home Screen ClipApp Installer")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                            Text("Add icons directly to your iPhone Home Screen that boot straight into each app (`omnicontainer://open?app=...`) without closing your other apps!")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }

                    Button {
                        workspace.installClipAppToHomeScreen(key: "all")
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down.on.square.fill")
                            Text("Install All 10 Home Screen ClipApps in 1 Tap")
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

                Text("Tap Any App to Open (Or Tap '+ Clip' for Home Screen Icon)")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)

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
                                    Text(isRunning ? "Resume" : "Open")
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
                                    Label("+ ClipApp", systemImage: "plus.square.on.square")
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

                Divider().background(Color.white.opacity(0.15))

                // Custom LiveContainer / External IPA ClipApp Builder
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom LiveContainer / External .IPA ClipApp Creator")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text("Generate a Home Screen ClipApp for any app inside LiveContainer (`livecontainer://open?bundle-id=...`) or import an `.ipa` file:")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    HStack {
                        TextField("Bundle ID (e.g. com.ross.keepwatch)", text: $customBundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("Create ClipApp") {
                            let bid = customBundleID.trimmingCharacters(in: .whitespaces)
                            if !bid.isEmpty {
                                workspace.installClipAppToHomeScreen(key: "lc-\(bid)")
                            }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import .IPA Package from Files", systemImage: "folder.fill.badge.plus")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.cyan)
                            .cornerRadius(10)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.05))
                .cornerRadius(14)
            }
            .padding()
        }
    }
}

// MARK: - Full Embedded Live App Modules (Kept Alive in ZStack Memory Simultaneously!)
struct EmbeddedLiveAppHost: View {
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
            MiniSentryCamModule()
        case "aniimo":
            MiniAniimoModule()
        case "racebolt":
            MiniWebModule(title: "Racebolt UK Ops", url: "https://raceboltuk.com", accent: .yellow)
        case "photopulse":
            MiniPhotoPulseModule()
        case "netradar":
            MiniWebModule(title: "NetRadar OpenSpeedTest (:30116)", url: "http://100.85.127.42:30116", accent: .teal)
        case "soulseekr":
            MiniWebModule(title: "SoulSeekr (Hearr :5070)", url: "http://100.85.127.42:5070", accent: .purple)
        case "zimadeck":
            MiniWebModule(title: "ZimaDeck & Komga (:30048)", url: "http://100.85.127.42:30048", accent: .mint)
        default:
            MiniWebModule(title: "Homelab Dashboard", url: "http://100.85.127.42:3000", accent: .cyan)
        }
    }
}

struct PersistentWebView: UIViewRepresentable {
    let urlString: String
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        if let u = URL(string: urlString) { w.load(URLRequest(url: u)) }
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MiniWebModule: View {
    let title: String
    let url: String
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption.bold()).foregroundColor(accent)
                Spacer()
                Text(url).font(.caption2.monospaced()).foregroundColor(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5))

            PersistentWebView(urlString: url)
        }
    }
}

struct MiniPhotoPulseModule: View {
    @State private var tab = 0
    @State private var code = ""
    @State private var container = "icloudpd"
    @State private var status = "iCloudPD + ImmichFrame Ready"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $tab) {
                Text("2FA & Sync").tag(0)
                Text("ImmichFrame (:9180)").tag(1)
                Text("Immich (:30041)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
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
            } else if tab == 1 {
                PersistentWebView(urlString: "http://100.85.127.42:9180")
            } else {
                PersistentWebView(urlString: "http://100.85.127.42:30041")
            }
        }
    }

    func send2FA(_ c: String) async {
        guard let u = URL(string: "http://100.85.127.42:9092/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "echo '\(c)' | sudo docker attach --sig-proxy=false \(container) 2>&1"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        _ = try? await URLSession.shared.data(for: req)
        status = "Submitted 2FA code \(c) to \(container)"
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
                        .overlay(Text("Live Node Screen (\(selectedNode))").font(.caption).foregroundColor(.gray))
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

            PersistentWebView(urlString: activeURL)
                .id(activeURL)
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

struct MiniSentryCamModule: View {
    @State private var cam = "tapo_c200"
    @State private var tick = 0
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Picker("Camera", selection: $cam) {
                    Text("Tapo C200").tag("tapo_c200")
                    Text("Ezviz / Bike").tag("ezviz")
                }
                .pickerStyle(.segmented)

                AsyncImage(url: URL(string: "http://100.85.127.42:5000/api/\(cam)/latest.jpg?t=\(tick)")) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)).frame(height: 180)
                }
                .cornerRadius(10)
                .onTapGesture { tick += 1 }

                Button("Refresh Live Snapshot") { tick += 1 }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
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
