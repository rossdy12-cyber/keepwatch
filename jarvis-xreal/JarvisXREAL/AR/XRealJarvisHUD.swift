import Combine
import CoreMotion
import SwiftUI
import UIKit

// MARK: - Live Homelab & Security Telemetry Store for XREAL HUD Wings

struct ARCameraInfo: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

struct ARCameraEvent: Identifiable, Codable, Hashable {
    var id: String
    var camera: String
    var label: String
    var startTime: Double
    var score: Int

    enum CodingKeys: String, CodingKey {
        case id, camera, label, score
        case startTime = "start_time"
    }

    var formattedTime: String {
        guard startTime > 0 else { return "" }
        let d = Date(timeIntervalSince1970: startTime)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

@MainActor
final class ARTelemetryStore: ObservableObject {
    static let shared = ARTelemetryStore()

    @Published var runningContainers: Int = 0
    @Published var totalContainers: Int = 0
    @Published var desktopOllamaOnline: Bool = false
    @Published var alertsEnabled: Bool = true
    @Published var cameras: [ARCameraInfo] = [
        ARCameraInfo(id: "doorbell", name: "Front Doorbell"),
        ARCameraInfo(id: "reolink_cam", name: "Garden / Reolink")
    ]
    @Published var cameraEvents: [ARCameraEvent] = []
    @Published var snapshotBuster: Int = Int(Date().timeIntervalSince1970)

    private var baseURL: String {
        let addr = ServerAddress.normalize(JarvisSettings.shared.config.address)
        return addr.isEmpty ? "https://jarvis.nas-server.co.uk" : addr
    }

    private func authedRequest(path: String, method: String = "GET") -> URLRequest? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        let secrets = JarvisSettings.shared.secrets
        if !secrets.token.isEmpty {
            req.setValue("Bearer \(secrets.token)", forHTTPHeaderField: "Authorization")
        }
        if !secrets.cfClientID.isEmpty && !secrets.cfClientSecret.isEmpty {
            req.setValue(secrets.cfClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secrets.cfClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return req
    }

    private func session() -> URLSession {
        let host = URL(string: baseURL)?.host
        TrustDelegate.shared.setTrusted(host: host, trusted: JarvisSettings.shared.config.trustSelfSigned)
        return httpSession
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadContainers() }
            group.addTask { await self.loadCameras() }
            group.addTask { await self.loadSystemBridge() }
        }
    }

    func loadContainers() async {
        struct ContainerItem: Decodable {
            let state: String
        }
        struct Resp: Decodable {
            let containers: [ContainerItem]
        }
        guard let req = authedRequest(path: "/api/keepwatch/containers") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            totalContainers = decoded.containers.count
            runningContainers = decoded.containers.filter { $0.state.lowercased() == "running" }.count
        }
    }

    func loadCameras() async {
        struct Resp: Decodable {
            let alerts_enabled: Bool?
            let cameras: [ARCameraInfo]?
            let events: [ARCameraEvent]?
        }
        guard let req = authedRequest(path: "/api/keepwatch/cameras") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            alertsEnabled = decoded.alerts_enabled ?? true
            if let cams = decoded.cameras, !cams.isEmpty {
                cameras = cams
            }
            cameraEvents = decoded.events ?? []
            snapshotBuster = Int(Date().timeIntervalSince1970)
        }
    }

    func loadSystemBridge() async {
        struct Resp: Decodable {
            let desktop_ollama_online: Bool?
        }
        guard let req = authedRequest(path: "/api/keepwatch/system-bridge") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            desktopOllamaOnline = decoded.desktop_ollama_online ?? false
        }
    }

    func snapshotURL(for camera: String) -> URL? {
        let token = JarvisSettings.shared.secrets.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "\(baseURL)/api/keepwatch/camera/\(camera)/snapshot?token=\(token)&t=\(snapshotBuster)")
    }
}

// MARK: - XREAL AR Glasses Display & IMU Motion Manager

enum XRealHUDMode: String, CaseIterable, Identifiable {
    case tactical = "Tactical HUD"
    case minimal = "Minimal Walk"
    case security = "Cam Overwatch"
    case music = "Arc Audio"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tactical: return "viewfinder.circle.fill"
        case .minimal: return "eyeglasses"
        case .security: return "video.badge.checkmark"
        case .music: return "waveform.circle.fill"
        }
    }
}

enum XRealHUDPalette: String, CaseIterable, Identifiable {
    case cyan = "Jarvis Cyan"
    case crimson = "Mark XLVI Crimson"
    case emerald = "Stealth Emerald"
    case amber = "Tactical Amber"

    var id: String { rawValue }

    var primary: Color {
        switch self {
        case .cyan: return Color(red: 0.0, green: 0.92, blue: 1.0)
        case .crimson: return Color(red: 1.0, green: 0.22, blue: 0.35)
        case .emerald: return Color(red: 0.15, green: 0.98, blue: 0.60)
        case .amber: return Color(red: 1.0, green: 0.76, blue: 0.12)
        }
    }
}

@MainActor
final class XRealDisplayManager: ObservableObject {
    static let shared = XRealDisplayManager()

    @Published var isExternalConnected = false
    @Published var externalResolution = "1920×1080"
    @Published var mode: XRealHUDMode = .tactical
    @Published var palette: XRealHUDPalette = .cyan
    @Published var hudOpacity: Double = 0.92
    @Published var hudScale: Double = 0.94 // Slightly inset so edges are crisp inside XREAL optics
    @Published var activeCameraIndex = 0
    @Published var cursorPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var pitchDegrees: Double = 0
    @Published var rollDegrees: Double = 0
    @Published var headingDegrees: Double = 0
    @Published var liveTranscript: String = ""

    private var externalWindow: UIWindow?
    private let motion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []
    private var cameraTimer: Timer?

    private init() {
        setupNotifications()
        startMotionTracking()
        startCameraRefreshTimer()
        checkScreens()
    }

    private func setupNotifications() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkScreens() }
        })
        observers.append(nc.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkScreens() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkScreens() }
        })
    }

    func checkScreens() {
        let screens = UIScreen.screens
        guard screens.count > 1, let extScreen = screens.dropFirst().first else {
            isExternalConnected = false
            externalWindow?.isHidden = true
            externalWindow = nil
            return
        }
        extScreen.overscanCompensation = .none
        let bounds = extScreen.bounds
        externalResolution = "\(Int(bounds.width))×\(Int(bounds.height))"
        isExternalConnected = true
        attachExternalHUD(to: extScreen)
    }

    private func attachExternalHUD(to screen: UIScreen) {
        let rootView = XRealOpticalHUDView()
            .environmentObject(self)
            .environmentObject(JarvisSettings.shared)
            .environmentObject(ChatStore.shared)
            .environmentObject(ARTelemetryStore.shared)

        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .black

        let window: UIWindow
        if let matchingScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.screen == screen }) {
            window = UIWindow(windowScene: matchingScene)
        } else {
            window = UIWindow(frame: screen.bounds)
            window.screen = screen
        }
        window.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        externalWindow = window
    }

    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pitchDegrees = data.attitude.pitch * 180.0 / .pi
                self.rollDegrees = data.attitude.roll * 180.0 / .pi
                let yaw = data.attitude.yaw * 180.0 / .pi
                self.headingDegrees = (yaw < 0 ? yaw + 360.0 : yaw)
            }
        }
    }

    private func startCameraRefreshTimer() {
        cameraTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                ARTelemetryStore.shared.snapshotBuster = Int(Date().timeIntervalSince1970)
            }
        }
    }

    func cycleCamera() {
        let count = max(1, ARTelemetryStore.shared.cameras.count)
        activeCameraIndex = (activeCameraIndex + 1) % count
    }
}

// MARK: - Pure-Black (#000000) Optical See-Through HUD Rendered on XREAL Glasses

struct XRealOpticalHUDView: View {
    @EnvironmentObject private var xreal: XRealDisplayManager
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var telemetry: ARTelemetryStore
    @ObservedObject private var music = MusicPlayer.shared

    private var glow: Color { xreal.palette.primary }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Pure #000000 black is completely unlit / transparent on XREAL Micro-OLED optics
                Color.black.ignoresSafeArea()

                Group {
                    switch xreal.mode {
                    case .tactical:
                        tacticalHUDLayout(size: geo.size)
                    case .minimal:
                        minimalWalkLayout(size: geo.size)
                    case .security:
                        securityOverwatchLayout(size: geo.size)
                    case .music:
                        musicArcLayout(size: geo.size)
                    }
                }
                .scaleEffect(xreal.hudScale)
                .opacity(xreal.hudOpacity)

                // Trackpad Laser Reticle Cursor
                Circle()
                    .strokeBorder(glow, lineWidth: 2)
                    .background(Circle().fill(glow.opacity(0.25)))
                    .frame(width: 18, height: 18)
                    .position(
                        x: geo.size.width * xreal.cursorPosition.x,
                        y: geo.size.height * xreal.cursorPosition.y
                    )
                    .shadow(color: glow, radius: 6)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 1. Full Tactical Iron Man J.A.R.V.I.S. HUD

    private func tacticalHUDLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            // Top Compass & Horizon Bar
            topCompassRibbon
                .padding(.top, 12)
                .padding(.horizontal, 28)

            Spacer()

            HStack(alignment: .center, spacing: 20) {
                // Left Telemetry Wing (TrueNAS + AI Brain + Security)
                VStack(alignment: .leading, spacing: 14) {
                    hudWingBox(title: "SYS // TRUENAS & BRAIN") {
                        VStack(alignment: .leading, spacing: 5) {
                            hudKeyValue("CONTAINERS", "\(telemetry.runningContainers)/\(telemetry.totalContainers) ONLINE")
                            hudKeyValue("GPU BRAIN", telemetry.desktopOllamaOnline ? "RTX DESKTOP" : "NAS CORE")
                            hudKeyValue("DOORBELL", telemetry.alertsEnabled ? "ARMED (AWAY)" : "HOME MUTE")
                            hudKeyValue("CORE LINK", settings.isConfigured ? "CONNECTED" : "UNCONFIGURED")
                        }
                    }

                    hudWingBox(title: "AUDIO // NAVIDROME") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(music.current?.displayTitle ?? "NO TRACK ACTIVE")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(music.current?.artist ?? "SAY 'PLAY MUSIC'")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(glow.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: min(280, size.width * 0.28))

                Spacer()

                // Center Arc Reactor Reticle & Live Jarvis Hologram
                centerArcReticle
                    .frame(maxWidth: min(440, size.width * 0.38))

                Spacer()

                // Right Security Wing (Live Frigate Cam PiP + Detections)
                VStack(alignment: .trailing, spacing: 14) {
                    hudWingBox(title: "OPTICS // FRIGATE FEED") {
                        let cams = telemetry.cameras
                        let cam = cams.indices.contains(xreal.activeCameraIndex) ? cams[xreal.activeCameraIndex] : ARCameraInfo(id: "doorbell", name: "Front Doorbell")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cam.name.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(glow)
                            if let url = telemetry.snapshotURL(for: cam.id) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable()
                                            .aspectRatio(16 / 9, contentMode: .fill)
                                            .frame(height: 110)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(glow.opacity(0.6), lineWidth: 1))
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(glow.opacity(0.4), lineWidth: 1)
                                            .frame(height: 110)
                                            .overlay(
                                                Text("SYNCING FEED…")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(glow.opacity(0.7))
                                            )
                                    }
                                }
                            }
                            if let latest = telemetry.cameraEvents.first {
                                Text("LAST: \(latest.label.uppercased()) (\(latest.score)%) · \(latest.formattedTime)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(width: min(280, size.width * 0.28))
            }
            .padding(.horizontal, 28)

            Spacer()

            // Bottom Voice Subtitle & Command Ticker
            bottomSubtitleBar
                .padding(.bottom, 14)
                .padding(.horizontal, 36)
        }
    }

    // MARK: 2. Minimal Walking / Driving HUD (Clear Center Vision)

    private func minimalWalkLayout(size: CGSize) -> some View {
        VStack {
            HStack {
                Text(Date(), style: .time)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Spacer()
                Text(String(format: "HDG %03.0f°", xreal.headingDegrees))
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Spacer()
                if let song = music.current {
                    Label(song.displayTitle, systemImage: "music.note")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(glow)
                        .lineLimit(1)
                }
            }
            .padding(24)

            Spacer()

            if let lastTurn = chat.turns.last {
                Text(lastTurn.text)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(14)
                    .background(Color.black.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(glow.opacity(0.7), lineWidth: 1))
                    .padding(.horizontal, 60)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: 3. Security Camera Overwatch HUD

    private func securityOverwatchLayout(size: CGSize) -> some View {
        VStack(spacing: 16) {
            topCompassRibbon.padding(.horizontal, 28).padding(.top, 12)
            HStack(spacing: 14) {
                ForEach(telemetry.cameras) { cam in
                    hudWingBox(title: cam.name.uppercased()) {
                        if let url = telemetry.snapshotURL(for: cam.id) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable()
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(glow.opacity(0.4), lineWidth: 1)
                                        .frame(height: 150)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            bottomSubtitleBar.padding(.horizontal, 36).padding(.bottom, 14)
        }
    }

    // MARK: 4. Arc Reactor Audio & Voice Visualizer

    private func musicArcLayout(size: CGSize) -> some View {
        VStack(spacing: 22) {
            Spacer()
            centerArcReticle
            if let song = music.current {
                Text(song.displayTitle.uppercased())
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Text(song.artist ?? "")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            bottomSubtitleBar.padding(.horizontal, 36).padding(.bottom, 14)
        }
    }

    // MARK: - HUD Sub-Components

    private var topCompassRibbon: some View {
        HStack(spacing: 16) {
            Text("J.A.R.V.I.S. // MK-VII XREAL OPTICS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)

            Spacer()

            HStack(spacing: 12) {
                Text(String(format: "HDG %03.0f°", xreal.headingDegrees))
                Text(String(format: "PTC %+02.0f°", xreal.pitchDegrees))
                Text(String(format: "RLL %+02.0f°", xreal.rollDegrees))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(glow)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(glow.opacity(0.6), lineWidth: 1))

            Spacer()

            Text(Date(), style: .time)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
        }
    }

    private var centerArcReticle: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(glow.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 160, height: 160)

                    Circle()
                        .trim(from: 0.05, to: 0.35)
                        .stroke(glow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 140, height: 140)
                        .rotationEffect(.degrees(t * 42))

                    Circle()
                        .trim(from: 0.55, to: 0.85)
                        .stroke(glow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 116, height: 116)
                        .rotationEffect(.degrees(-t * 58))

                    Circle()
                        .stroke(glow.opacity(0.45), lineWidth: 1)
                        .frame(width: 72, height: 72)

                    Image(systemName: chat.isSending ? "waveform" : "scope")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(glow)
                }
                .shadow(color: glow.opacity(0.6), radius: 10)

                if let lastAssistant = chat.turns.last(where: { $0.role == .assistant }) {
                    Text(lastAssistant.text)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .padding(12)
                        .background(Color.black.opacity(0.82))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(glow.opacity(0.65), lineWidth: 1)
                        )
                }
            }
        }
    }

    private var bottomSubtitleBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(chat.isSending ? Theme.warning : glow)
                .frame(width: 8, height: 8)
            Text(
                !xreal.liveTranscript.isEmpty
                    ? "VOICE INPUT: \"\(xreal.liveTranscript)\""
                    : (chat.isSending ? "JARVIS PROCESSING…" : "READY // SLIDE THUMB ON IPHONE TRACKPAD OR DOUBLE-TAP TO SPEAK")
            )
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(glow)
            .lineLimit(1)
            Spacer()
            Text(xreal.isExternalConnected ? "XREAL OPTICS: \(xreal.externalResolution)" : "LOCAL VISOR PREVIEW")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(glow.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(glow.opacity(0.45), lineWidth: 1)
        )
    }

    private func hudWingBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
            Divider().overlay(glow.opacity(0.5))
            content()
        }
        .padding(10)
        .background(Color.black.opacity(0.75))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(glow.opacity(0.55), lineWidth: 1)
        )
    }

    private func hudKeyValue(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
        }
    }
}

// MARK: - iPhone Pocket Trackpad & XREAL Cockpit View

struct XRealCockpitView: View {
    var openSettings: () -> Void

    @EnvironmentObject private var xreal: XRealDisplayManager
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var telemetry: ARTelemetryStore
    @ObservedObject private var music = MusicPlayer.shared
    @StateObject private var listener = SpeechRecognizer()

    @State private var showFullVisorOnPhone = false

    private let quickCommands: [(String, String)] = [
        ("System Status", "Give me a concise tactical homelab and server status report."),
        ("Doorbell Check", "Are there any recent person or parcel detections on the cameras?"),
        ("Morning Briefing", "Give me a quick J.A.R.V.I.S. daily briefing."),
        ("Shuffle Music", "shuffle my music")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // XREAL Connection Banner
                HStack(spacing: 10) {
                    Image(systemName: xreal.isExternalConnected ? "eyeglasses" : "cable.connector.horizontal")
                        .font(.title3)
                        .foregroundStyle(xreal.palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xreal.isExternalConnected
                             ? "XREAL Glasses Active (\(xreal.externalResolution))"
                             : "Plug XREAL Glasses into USB-C")
                            .font(.subheadline.weight(.bold))
                        Text(xreal.isExternalConnected
                             ? "Pure-black (#000000) optical see-through HUD is live on your lenses."
                             : "Auto-projects 1080p optical HUD onto your XREAL glasses on plug-in.")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

                // Live Mini Preview / Full-Screen Visor Toggle
                ZStack(alignment: .topTrailing) {
                    XRealOpticalHUDView()
                        .frame(height: showFullVisorOnPhone ? 300 : 180)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(xreal.palette.primary.opacity(0.6), lineWidth: 1.5)
                        )

                    Button {
                        withAnimation { showFullVisorOnPhone.toggle() }
                    } label: {
                        Image(systemName: showFullVisorOnPhone ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                            .padding(8)
                            .background(.black.opacity(0.75), in: Circle())
                            .foregroundStyle(xreal.palette.primary)
                    }
                    .padding(8)
                }

                // Quick Tactical Voice/Command Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickCommands, id: \.0) { label, prompt in
                            Button {
                                sendToJarvis(prompt)
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.surfaceRaised, in: Capsule())
                                    .overlay(Capsule().stroke(xreal.palette.primary.opacity(0.45), lineWidth: 1))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }

                // Eyes-Free Touch Trackpad & Double-Tap Voice Trigger
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Theme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(listener.isListening ? Theme.danger : xreal.palette.primary.opacity(0.45), lineWidth: 1.5)
                            )

                        VStack(spacing: 6) {
                            Image(systemName: listener.isListening ? "waveform.circle.fill" : "hand.point.up.braille.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(listener.isListening ? Theme.danger : xreal.palette.primary)
                            Text(listener.isListening ? "LISTENING… DOUBLE-TAP OR TAP BUTTON TO SEND" : "EYES-FREE AR TRACKPAD")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Slide thumb to aim AR laser reticle · Double-tap pad to speak")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = min(max(value.location.x / max(1, geo.size.width), 0.05), 0.95)
                                let y = min(max(value.location.y / max(1, geo.size.height), 0.05), 0.95)
                                xreal.cursorPosition = CGPoint(x: x, y: y)
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            toggleVoice()
                        }
                    )
                }
                .frame(minHeight: 105)

                // Giant Eyes-Free Action Buttons
                HStack(spacing: 10) {
                    Button {
                        toggleVoice()
                    } label: {
                        Label(listener.isListening ? "Send Voice" : "Talk to Jarvis",
                              systemImage: listener.isListening ? "stop.circle.fill" : "mic.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(listener.isListening ? Theme.danger : xreal.palette.primary)

                    Button {
                        xreal.cycleCamera()
                    } label: {
                        Label("Next Cam", systemImage: "video.fill")
                            .font(.caption.weight(.bold))
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(xreal.palette.primary)

                    Button {
                        music.togglePlayPause()
                    } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(xreal.palette.primary)
                }

                // HUD Mode, Color Palette & Brightness Controls
                HStack(spacing: 10) {
                    Picker("HUD Mode", selection: $xreal.mode) {
                        ForEach(XRealHUDMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("HUD Color", selection: $xreal.palette) {
                        ForEach(XRealHUDPalette.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 4) {
                        Image(systemName: "sun.max.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                        Slider(value: $xreal.hudOpacity, in: 0.3...1.0)
                            .tint(xreal.palette.primary)
                    }
                }
            }
            .padding(14)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("J.A.R.V.I.S. // XREAL AR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await telemetry.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onChange(of: listener.transcript) { newValue in
                xreal.liveTranscript = newValue
            }
            .task {
                xreal.checkScreens()
                await telemetry.refreshAll()
            }
        }
    }

    private func toggleVoice() {
        if listener.isListening {
            let spoken = listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            xreal.liveTranscript = ""
            guard !spoken.isEmpty else { return }
            sendToJarvis(spoken)
        } else {
            speaker.stop()
            listener.start { finalSpeech in
                let trimmed = finalSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
                xreal.liveTranscript = ""
                guard !trimmed.isEmpty else { return }
                sendToJarvis(trimmed)
            }
        }
    }

    private func sendToJarvis(_ text: String) {
        if let cmd = MusicCommand.parse(text) {
            Task {
                if let reply = await MusicDJ.handle(cmd, account: settings.navidrome) {
                    chat.addExchange(user: text, reply: reply)
                    speaker.speak(reply, client: settings.client)
                }
            }
            return
        }
        chat.send(text, settings: settings) { reply, audioURL in
            speaker.speak(reply, audio: audioURL, client: settings.client)
        }
    }
}
