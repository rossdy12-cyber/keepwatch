import ARKit
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

struct ARContainerSummary: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var state: String
    var status: String
}

@MainActor
final class ARTelemetryStore: ObservableObject {
    static let shared = ARTelemetryStore()

    @Published var runningContainers: Int = 0
    @Published var totalContainers: Int = 0
    @Published var topContainers: [ARContainerSummary] = []
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
        struct Resp: Decodable {
            let containers: [ARContainerSummary]
        }
        guard let req = authedRequest(path: "/api/keepwatch/containers") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            totalContainers = decoded.containers.count
            runningContainers = decoded.containers.filter { $0.state.lowercased() == "running" }.count
            topContainers = Array(decoded.containers.prefix(8))
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

// MARK: - XREAL Spatial 3-DoF Modes, Head Tracking Sources & Palettes

enum XRealSpatialAnchorMode: String, CaseIterable, Identifiable {
    case worldAnchored = "3D World-Anchored"
    case gazeSwitch = "Head-Turn Switcher"
    case smoothFollow = "Smooth Parallax"
    case headLocked = "0-DoF Visor Lock"

    var id: String { rawValue }
}

enum XRealHeadTrackingSource: String, CaseIterable, Identifiable {
    case auto = "Auto (AirPods + Face + IMU)"
    case faceCamera = "Front Camera 3D Head"
    case airpods = "AirPods Head Motion"
    case deviceIMU = "iPhone Gyro IMU"

    var id: String { rawValue }
}

enum XRealGazeZone: String {
    case leftWing = "LEFT WING // SYSTEMS & DOCKER"
    case centerCore = "CENTER // J.A.R.V.I.S. CORE"
    case rightWing = "RIGHT WING // OPTICS & AUDIO"
    case overhead = "OVERHEAD // TACTICAL CANOPY"
    case commandDock = "LOWER // GAZE COMMAND DOCK"
}

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

// MARK: - ARKit Front Camera 3D Head Pose Delegate

final class FacePoseTrackerDelegate: NSObject, ARSessionDelegate {
    var onPoseUpdate: ((Double, Double, Double) -> Void)?

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else { return }
        let m = face.transform
        // Extract Euler yaw, pitch, roll in degrees from the 4x4 face transform matrix
        let pitchRad = asin(-max(-1.0, min(1.0, m.columns.2.y)))
        let yawRad = atan2(m.columns.2.x, m.columns.2.z)
        let rollRad = atan2(m.columns.0.y, m.columns.1.y)

        let yawDeg = Double(yawRad) * 180.0 / .pi
        let pitchDeg = Double(pitchRad) * 180.0 / .pi
        let rollDeg = Double(rollRad) * 180.0 / .pi
        onPoseUpdate?(yawDeg, pitchDeg, rollDeg)
    }
}

// MARK: - XREAL Display & 3-DoF Spatial Head Tracker Manager

@MainActor
final class XRealDisplayManager: ObservableObject {
    static let shared = XRealDisplayManager()

    @Published var isExternalConnected = false
    @Published var externalResolution = "1920×1080"
    @Published var mode: XRealHUDMode = .tactical
    @Published var spatialMode: XRealSpatialAnchorMode = .worldAnchored
    @Published var trackingSource: XRealHeadTrackingSource = .auto {
        didSet { reconfigureHeadTracking() }
    }
    @Published var palette: XRealHUDPalette = .cyan
    @Published var hudOpacity: Double = 0.94
    @Published var hudScale: Double = 0.94
    @Published var spatialSensitivity: Double = 16.0 // Pixels per degree of head turn
    @Published var activeCameraIndex = 0
    @Published var cursorPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Raw & Calibrated Relative 3-DoF Head Angles (Degrees)
    @Published var headYaw: Double = 0       // - Left, + Right
    @Published var headPitch: Double = 0     // + Up, - Down
    @Published var headRoll: Double = 0      // Tilt
    @Published var compassHeading: Double = 0
    @Published var activeTrackerLabel: String = "Initializing…"
    @Published var activeGazeZone: XRealGazeZone = .centerCore
    @Published var liveTranscript: String = ""

    // Dwell-to-Trigger state when looking at the Lower Command Dock
    @Published var dwellTargetIndex: Int? = nil
    @Published var dwellProgress: Double = 0.0
    var onGazeCommandTriggered: ((String) -> Void)?

    private var rawYaw: Double = 0
    private var rawPitch: Double = 0
    private var rawRoll: Double = 0
    private var centerYawOffset: Double = 0
    private var centerPitchOffset: Double = 0
    private var centerRollOffset: Double = 0
    private var hasInitialCenter = false

    private var lastAirPodsTimestamp: Date = .distantPast
    private var lastFaceTimestamp: Date = .distantPast

    private var externalWindow: UIWindow?
    private let deviceMotion = CMMotionManager()
    private let headphoneMotion = CMHeadphoneMotionManager()
    private var arSession: ARSession?
    private let faceDelegate = FacePoseTrackerDelegate()
    private var observers: [NSObjectProtocol] = []
    private var cameraTimer: Timer?
    private var dwellTimer: Timer?

    private init() {
        setupNotifications()
        startAllTrackers()
        startCameraRefreshTimer()
        startDwellTimer()
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

    // MARK: - Multi-Source 60Hz 3-DoF Head Tracking (AirPods + TrueDepth Face + Device IMU)

    private func startAllTrackers() {
        // 1. AirPods / Beats Headphone IMU (Direct head tracking even with iPhone in pocket)
        if headphoneMotion.isDeviceMotionAvailable {
            headphoneMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let motion else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastAirPodsTimestamp = Date()
                    guard self.trackingSource == .auto || self.trackingSource == .airpods else { return }
                    let yaw = -motion.attitude.yaw * 180.0 / .pi
                    let pitch = motion.attitude.pitch * 180.0 / .pi
                    let roll = motion.attitude.roll * 180.0 / .pi
                    self.activeTrackerLabel = "AirPods 3D Head IMU"
                    self.ingestHeadAngles(yaw: yaw, pitch: pitch, roll: roll)
                }
            }
        }

        // 2. ARKit TrueDepth Front Camera Head Pose (Tracks head rotation while looking near phone)
        startFaceTrackingIfSupported()

        // 3. Device Gyroscope & Magnetometer Attitude
        if deviceMotion.isDeviceMotionAvailable {
            deviceMotion.deviceMotionUpdateInterval = 1.0 / 60.0
            deviceMotion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let rawCompass = data.attitude.yaw * 180.0 / .pi
                    self.compassHeading = rawCompass < 0 ? rawCompass + 360.0 : rawCompass

                    let now = Date()
                    let airpodsActive = now.timeIntervalSince(self.lastAirPodsTimestamp) < 0.6
                    let faceActive = now.timeIntervalSince(self.lastFaceTimestamp) < 0.6

                    let useDeviceIMU: Bool
                    switch self.trackingSource {
                    case .deviceIMU:
                        useDeviceIMU = true
                    case .auto:
                        useDeviceIMU = !airpodsActive && !faceActive
                    case .airpods, .faceCamera:
                        useDeviceIMU = false
                    }

                    guard useDeviceIMU else { return }
                    self.activeTrackerLabel = "iPhone 60Hz Spatial IMU"
                    let yaw = -data.attitude.yaw * 180.0 / .pi
                    let pitch = data.attitude.pitch * 180.0 / .pi
                    let roll = data.attitude.roll * 180.0 / .pi
                    self.ingestHeadAngles(yaw: yaw, pitch: pitch, roll: roll)
                }
            }
        }
    }

    private func startFaceTrackingIfSupported() {
        guard ARFaceTrackingConfiguration.isSupported else { return }
        guard trackingSource == .auto || trackingSource == .faceCamera else {
            arSession?.pause()
            return
        }
        if arSession == nil {
            let session = ARSession()
            faceDelegate.onPoseUpdate = { [weak self] yaw, pitch, roll in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastFaceTimestamp = Date()
                    let airpodsActive = Date().timeIntervalSince(self.lastAirPodsTimestamp) < 0.6
                    guard self.trackingSource == .faceCamera || (self.trackingSource == .auto && !airpodsActive) else { return }
                    self.activeTrackerLabel = "TrueDepth 3D Head Pose"
                    // Invert yaw so turning head right produces positive headYaw
                    self.ingestHeadAngles(yaw: -yaw, pitch: -pitch, roll: roll)
                }
            }
            session.delegate = faceDelegate
            arSession = session
        }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        arSession?.run(config, options: [.resetTracking])
    }

    private func reconfigureHeadTracking() {
        hasInitialCenter = false
        if trackingSource == .auto || trackingSource == .faceCamera {
            startFaceTrackingIfSupported()
        } else {
            arSession?.pause()
        }
    }

    private func ingestHeadAngles(yaw: Double, pitch: Double, roll: Double) {
        rawYaw = yaw
        rawPitch = pitch
        rawRoll = roll

        if !hasInitialCenter {
            centerYawOffset = yaw
            centerPitchOffset = pitch
            centerRollOffset = roll
            hasInitialCenter = true
        }

        let targetYaw = Self.normalizeAngle(yaw - centerYawOffset)
        let targetPitch = max(-65, min(65, pitch - centerPitchOffset))
        let targetRoll = max(-45, min(45, Self.normalizeAngle(roll - centerRollOffset)))

        // Smooth low-pass filter so head motion is silky-smooth at 60fps without jitter
        let alpha = 0.28
        headYaw = headYaw + alpha * (targetYaw - headYaw)
        headPitch = headPitch + alpha * (targetPitch - headPitch)
        headRoll = headRoll + alpha * (targetRoll - headRoll)

        // Update active gaze zone based on where the user's head is pointing
        if headPitch > 15 {
            activeGazeZone = .overhead
        } else if headPitch < -13 {
            activeGazeZone = .commandDock
        } else if headYaw < -14 {
            activeGazeZone = .leftWing
        } else if headYaw > 14 {
            activeGazeZone = .rightWing
        } else {
            activeGazeZone = .centerCore
        }
    }

    /// Re-centers the 3D HUD so the user's current head direction becomes (0° yaw, 0° pitch, 0° roll).
    func recenterHUD() {
        centerYawOffset = rawYaw
        centerPitchOffset = rawPitch
        centerRollOffset = rawRoll
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            headYaw = 0
            headPitch = 0
            headRoll = 0
            cursorPosition = CGPoint(x: 0.5, y: 0.5)
        }
    }

    private static func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360.0)
        if a > 180.0 { a -= 360.0 }
        if a < -180.0 { a += 360.0 }
        return a
    }

    // MARK: - Gaze Dwell Selection Timer (Hands-Free Command Execution)

    private func startDwellTimer() {
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeGazeZone == .commandDock else {
                    self.dwellTargetIndex = nil
                    self.dwellProgress = 0
                    return
                }
                // Map headYaw (-30° ... +30°) across the 4 dock buttons
                let clamped = max(-28.0, min(28.0, self.headYaw))
                let normalized = (clamped + 28.0) / 56.0 // 0.0 ... 1.0
                let idx = min(3, max(0, Int(normalized * 4.0)))
                if self.dwellTargetIndex == idx {
                    self.dwellProgress += 0.08 / 1.4
                    if self.dwellProgress >= 1.0 {
                        self.dwellProgress = 0
                        self.triggerDockItem(at: idx)
                    }
                } else {
                    self.dwellTargetIndex = idx
                    self.dwellProgress = 0
                }
            }
        }
    }

    private func triggerDockItem(at index: Int) {
        switch index {
        case 0:
            onGazeCommandTriggered?("Give me a concise tactical homelab and server status report.")
        case 1:
            cycleCamera()
        case 2:
            MusicPlayer.shared.togglePlayPause()
        case 3:
            recenterHUD()
        default:
            break
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

// MARK: - Pure-Black (#000000) 3-DoF Spatial Optical HUD Rendered on XREAL Glasses

struct XRealOpticalHUDView: View {
    @EnvironmentObject private var xreal: XRealDisplayManager
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var telemetry: ARTelemetryStore
    @ObservedObject private var music = MusicPlayer.shared

    private var glow: Color { xreal.palette.primary }

    // Computed 3-DoF Spatial Shifts based on Head Yaw, Pitch, and Roll
    private var spatialOffsetX: CGFloat {
        switch xreal.spatialMode {
        case .worldAnchored:
            // Panoramic world-locked canvas: turning head right shifts world-anchored canvas left
            return CGFloat(-xreal.headYaw * xreal.spatialSensitivity)
        case .smoothFollow:
            return CGFloat(-xreal.headYaw * (xreal.spatialSensitivity * 0.45))
        case .gazeSwitch, .headLocked:
            return 0
        }
    }

    private var spatialOffsetY: CGFloat {
        switch xreal.spatialMode {
        case .worldAnchored:
            return CGFloat(xreal.headPitch * (xreal.spatialSensitivity * 0.72))
        case .smoothFollow:
            return CGFloat(xreal.headPitch * (xreal.spatialSensitivity * 0.35))
        case .gazeSwitch, .headLocked:
            return 0
        }
    }

    private var horizonRollAngle: Double {
        xreal.spatialMode == .headLocked ? 0 : -xreal.headRoll * 0.55
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Pure #000000 black is completely unlit / transparent on XREAL Micro-OLED optics
                Color.black.ignoresSafeArea()

                // Subtle Helmet Artificial Horizon Pitch Ladder that tilts & shifts with your head
                if xreal.spatialMode != .headLocked {
                    artificialHorizonOverlay(size: geo.size)
                }

                // Main Spatial Content
                Group {
                    if xreal.spatialMode == .gazeSwitch {
                        gazeSwitchHUDLayout(size: geo.size)
                    } else {
                        switch xreal.mode {
                        case .tactical:
                            panoramicWorldHUDLayout(size: geo.size)
                        case .minimal:
                            minimalWalkLayout(size: geo.size)
                        case .security:
                            securityOverwatchLayout(size: geo.size)
                        case .music:
                            musicArcLayout(size: geo.size)
                        }
                    }
                }
                .offset(x: spatialOffsetX, y: spatialOffsetY)
                .rotation3DEffect(
                    .degrees(xreal.spatialMode == .headLocked ? 0 : xreal.headYaw * 0.22),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.45
                )
                .rotation3DEffect(
                    .degrees(xreal.spatialMode == .headLocked ? 0 : -xreal.headPitch * 0.18),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.45
                )
                .scaleEffect(xreal.hudScale)
                .opacity(xreal.hudOpacity)
                .animation(.interpolatingSpring(stiffness: 140, damping: 19), value: xreal.headYaw)
                .animation(.interpolatingSpring(stiffness: 140, damping: 19), value: xreal.headPitch)

                // Pinned Visor Top Edge Indicator (shows which spatial wing you're looking at)
                visorTopGazeIndicator
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 6)

                // Trackpad / Gaze Laser Reticle Cursor
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

    // MARK: - Artificial Horizon & Sliding Compass Tape

    private func artificialHorizonOverlay(size: CGSize) -> some View {
        ZStack {
            // Pitch ladder bars that shift vertically with headPitch and roll with headRoll
            ForEach([-20, -10, 0, 10, 20], id: \.self) { rung in
                let yShift = CGFloat(Double(rung) - xreal.headPitch) * 6.5
                HStack(spacing: 50) {
                    Rectangle()
                        .fill(glow.opacity(rung == 0 ? 0.35 : 0.16))
                        .frame(width: rung == 0 ? 48 : 24, height: rung == 0 ? 1.5 : 1)
                    Text("\(rung > 0 ? "+" : "")\(rung)°")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(glow.opacity(0.35))
                    Rectangle()
                        .fill(glow.opacity(rung == 0 ? 0.35 : 0.16))
                        .frame(width: rung == 0 ? 48 : 24, height: rung == 0 ? 1.5 : 1)
                }
                .offset(y: yShift)
            }
        }
        .rotationEffect(.degrees(horizonRollAngle))
        .allowsHitTesting(false)
    }

    private var visorTopGazeIndicator: some View {
        HStack(spacing: 12) {
            Text(xreal.activeGazeZone.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
            Text(String(format: "YAW %+03.0f° · PTC %+02.0f° · RLL %+02.0f°", xreal.headYaw, xreal.headPitch, xreal.headRoll))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(glow.opacity(0.5), lineWidth: 1))
    }

    // MARK: - 1A. Panoramic 3D World-Anchored HUD (Expands as You Turn Your Head Left / Right / Up / Down)

    private func panoramicWorldHUDLayout(size: CGSize) -> some View {
        let wingWidth = max(310, size.width * 0.44)
        let centerWidth = max(360, size.width * 0.46)

        return VStack(spacing: 18) {
            // OVERHEAD CANOPY (Revealed / scales up when looking UP: headPitch > 12°)
            overheadCanopyBar(size: size)
                .scaleEffect(xreal.activeGazeZone == .overhead ? 1.08 : 0.94)
                .opacity(xreal.activeGazeZone == .overhead ? 1.0 : 0.65)

            // 3-WING WIDE SPATIAL COCKPIT (Left Wing — Center Core — Right Wing)
            HStack(alignment: .center, spacing: 38) {
                // LEFT SPATIAL WING (Swings into center view when you turn your head LEFT)
                leftSystemsWing(isFocused: xreal.activeGazeZone == .leftWing)
                    .frame(width: wingWidth)
                    .scaleEffect(xreal.activeGazeZone == .leftWing ? 1.10 : 0.92)
                    .opacity(xreal.activeGazeZone == .leftWing ? 1.0 : 0.62)
                    .rotation3DEffect(.degrees(16), axis: (x: 0, y: 1, z: 0), perspective: 0.5)

                // CENTER CORE RETICLE (In front of you at 0° Yaw)
                VStack(spacing: 12) {
                    topCompassRibbon
                    centerArcReticle
                    bottomSubtitleBar
                }
                .frame(width: centerWidth)
                .scaleEffect(xreal.activeGazeZone == .centerCore ? 1.03 : 0.92)
                .opacity(xreal.activeGazeZone == .centerCore ? 1.0 : 0.68)

                // RIGHT SPATIAL WING (Swings into center view when you turn your head RIGHT)
                rightOpticsWing(isFocused: xreal.activeGazeZone == .rightWing)
                    .frame(width: wingWidth)
                    .scaleEffect(xreal.activeGazeZone == .rightWing ? 1.10 : 0.92)
                    .opacity(xreal.activeGazeZone == .rightWing ? 1.0 : 0.62)
                    .rotation3DEffect(.degrees(-16), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            }

            // LOWER GAZE COMMAND DOCK (Rises into focus when looking DOWN: headPitch < -12°)
            lowerGazeCommandDock
                .scaleEffect(xreal.activeGazeZone == .commandDock ? 1.10 : 0.90)
                .opacity(xreal.activeGazeZone == .commandDock ? 1.0 : 0.55)
        }
    }

    // MARK: - 1B. Gaze-Switch HUD Mode (Full-Screen Morph on Head Turn)

    private func gazeSwitchHUDLayout(size: CGSize) -> some View {
        VStack(spacing: 14) {
            topCompassRibbon
                .padding(.horizontal, 28)
                .padding(.top, 24)

            Spacer()

            Group {
                switch xreal.activeGazeZone {
                case .leftWing:
                    leftSystemsWing(isFocused: true)
                        .frame(maxWidth: min(680, size.width * 0.85))
                case .rightWing:
                    rightOpticsWing(isFocused: true)
                        .frame(maxWidth: min(680, size.width * 0.85))
                case .overhead:
                    overheadCanopyBar(size: size)
                        .frame(maxWidth: min(680, size.width * 0.85))
                case .commandDock:
                    lowerGazeCommandDock
                        .frame(maxWidth: min(720, size.width * 0.88))
                case .centerCore:
                    centerArcReticle
                        .frame(maxWidth: min(500, size.width * 0.72))
                }
            }
            .transition(.opacity.combined(with: .scale))

            Spacer()

            bottomSubtitleBar
                .padding(.horizontal, 36)
                .padding(.bottom, 14)
        }
    }

    // MARK: - Spatial Wing Views (Expand with Extra Details When Looked At)

    private func leftSystemsWing(isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            hudWingBox(title: isFocused ? "◀ FOCUSED // TRUENAS & AI BRAIN" : "◀ LOOK LEFT // SYSTEMS") {
                VStack(alignment: .leading, spacing: 6) {
                    hudKeyValue("CONTAINERS", "\(telemetry.runningContainers)/\(telemetry.totalContainers) RUNNING")
                    hudKeyValue("AI COMPUTE", telemetry.desktopOllamaOnline ? "RTX 5070 DESKTOP" : "NAS CORE")
                    hudKeyValue("SECURITY MODE", telemetry.alertsEnabled ? "ARMED (AWAY)" : "HOME MUTE")
                    hudKeyValue("HEAD TRACKER", xreal.activeTrackerLabel.uppercased())
                    if isFocused && !telemetry.topContainers.isEmpty {
                        Divider().overlay(glow.opacity(0.4))
                        Text("LIVE DOCKER FLEET:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(glow)
                        ForEach(telemetry.topContainers.prefix(6)) { c in
                            HStack {
                                Circle()
                                    .fill(c.state.lowercased() == "running" ? Theme.good : Theme.danger)
                                    .frame(width: 6, height: 6)
                                Text(c.name.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text(c.state.uppercased())
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(glow.opacity(0.85))
                            }
                        }
                    }
                }
            }

            hudWingBox(title: "AUDIO // NAVIDROME DECK") {
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
    }

    private func rightOpticsWing(isFocused: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            hudWingBox(title: isFocused ? "FOCUSED // LIVE FRIGATE OPTICS ▶" : "LOOK RIGHT // CAMERAS ▶") {
                let cams = telemetry.cameras
                let cam = cams.indices.contains(xreal.activeCameraIndex) ? cams[xreal.activeCameraIndex] : ARCameraInfo(id: "doorbell", name: "Front Doorbell")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(cam.name.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(glow)
                        Spacer()
                        Text(isFocused ? "HI-RES FEED" : "PIP FEED")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(glow.opacity(0.75))
                    }
                    if let url = telemetry.snapshotURL(for: cam.id) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable()
                                    .aspectRatio(16 / 9, contentMode: .fill)
                                    .frame(height: isFocused ? 165 : 115)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(glow.opacity(0.8), lineWidth: isFocused ? 2 : 1))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(glow.opacity(0.4), lineWidth: 1)
                                    .frame(height: isFocused ? 165 : 115)
                                    .overlay(
                                        Text("SYNCING CAMERA OPTICS…")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(glow.opacity(0.7))
                                    )
                            }
                        }
                    }
                    if isFocused && !telemetry.cameraEvents.isEmpty {
                        Divider().overlay(glow.opacity(0.4))
                        Text("RECENT AI DETECTIONS:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(glow)
                        ForEach(telemetry.cameraEvents.prefix(3)) { ev in
                            Text("• \(ev.camera.uppercased()): \(ev.label.uppercased()) (\(ev.score)%) · \(ev.formattedTime)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                    } else if let latest = telemetry.cameraEvents.first {
                        Text("LAST: \(latest.label.uppercased()) (\(latest.score)%) · \(latest.formattedTime)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func overheadCanopyBar(size: CGSize) -> some View {
        HStack(spacing: 24) {
            Label("OVERHEAD TELEMETRY CANOPY", systemImage: "safari.fill")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
            Text(String(format: "MAGNETIC HDG %03.0f°", xreal.compassHeading))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
            Text("OPTICS: \(xreal.externalResolution)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(glow)
            Text("TRACKER: \(xreal.activeTrackerLabel.uppercased())")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(glow.opacity(0.6), lineWidth: 1))
    }

    private var lowerGazeCommandDock: some View {
        let items: [(String, String)] = [
            ("STATUS REPORT", "cpu"),
            ("NEXT CAMERA", "video.fill"),
            (music.isPlaying ? "PAUSE AUDIO" : "PLAY AUDIO", music.isPlaying ? "pause.fill" : "play.fill"),
            ("RECENTER 0°", "scope")
        ]
        return VStack(spacing: 6) {
            Text("▼ LOWER GAZE COMMAND DOCK (LOOK DOWN & HOLD 1.4S TO TRIGGER HANDS-FREE) ▼")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)

            HStack(spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    let isDwelling = (xreal.activeGazeZone == .commandDock && xreal.dwellTargetIndex == idx)
                    HStack(spacing: 6) {
                        Image(systemName: item.1)
                            .font(.system(size: 11, weight: .bold))
                        Text(item.0)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(isDwelling ? .black : glow)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isDwelling ? glow.opacity(0.25) : Color.black.opacity(0.8))
                            if isDwelling {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(glow)
                                    .scaleEffect(x: max(0.05, xreal.dwellProgress), y: 1.0, anchor: .leading)
                            }
                        }
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(glow, lineWidth: isDwelling ? 2 : 1))
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(glow.opacity(0.55), lineWidth: 1))
    }

    // MARK: 2. Minimal Walking / Driving HUD (Clear Center Vision)

    private func minimalWalkLayout(size: CGSize) -> some View {
        VStack {
            HStack {
                Text(Date(), style: .time)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Spacer()
                Text(String(format: "HDG %03.0f° (YAW %+02.0f°)", xreal.compassHeading, xreal.headYaw))
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
            Text("J.A.R.V.I.S. // 3-DOF SPATIAL OPTICS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)

            Spacer()

            // Sliding Compass Tape that shifts with Head Yaw
            HStack(spacing: 12) {
                Text(String(format: "HDG %03.0f°", xreal.compassHeading))
                Text(String(format: "YAW %+03.0f°", xreal.headYaw))
                Text(String(format: "PTC %+02.0f°", xreal.headPitch))
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
                        .frame(width: 155, height: 155)

                    Circle()
                        .trim(from: 0.05, to: 0.35)
                        .stroke(glow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 136, height: 136)
                        .rotationEffect(.degrees(t * 42 + xreal.headYaw * 1.5))

                    Circle()
                        .trim(from: 0.55, to: 0.85)
                        .stroke(glow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 112, height: 112)
                        .rotationEffect(.degrees(-t * 58 - xreal.headPitch * 1.5))

                    Circle()
                        .stroke(glow.opacity(0.45), lineWidth: 1)
                        .frame(width: 70, height: 70)

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
                    : (chat.isSending ? "JARVIS PROCESSING…" : "TURN HEAD LEFT/RIGHT/UP/DOWN TO PAN 3D HUD · DOUBLE-TAP PAD TO SPEAK")
            )
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(glow)
            .lineLimit(1)
            Spacer()
            Text(xreal.spatialMode.rawValue.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(glow.opacity(0.8))
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
        .background(Color.black.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(glow.opacity(0.6), lineWidth: 1)
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

// MARK: - iPhone Pocket Trackpad & 3-DoF Spatial Cockpit View

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
            ScrollView {
                VStack(spacing: 12) {
                    // XREAL Connection & Live 3-DoF Head Tracker Status Banner
                    HStack(spacing: 10) {
                        Image(systemName: xreal.isExternalConnected ? "eyeglasses" : "gyroscope")
                            .font(.title3)
                            .foregroundStyle(xreal.palette.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(xreal.isExternalConnected
                                 ? "XREAL Active (\(xreal.externalResolution)) · \(xreal.activeTrackerLabel)"
                                 : "3-DoF Head Tracking Active · \(xreal.activeTrackerLabel)")
                                .font(.subheadline.weight(.bold))
                            Text(String(format: "Gaze: %@  |  Yaw %+03.0f° · Pitch %+02.0f° · Roll %+02.0f°",
                                        xreal.activeGazeZone.rawValue, xreal.headYaw, xreal.headPitch, xreal.headRoll))
                                .font(.caption2.monospaced())
                                .foregroundStyle(xreal.palette.primary)
                        }
                        Spacer()
                        Button {
                            xreal.recenterHUD()
                        } label: {
                            Label("Recenter", systemImage: "scope")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(xreal.palette.primary)
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

                    // Live Mini Preview / Full-Screen Visor Toggle
                    ZStack(alignment: .topTrailing) {
                        XRealOpticalHUDView()
                            .frame(height: showFullVisorOnPhone ? 290 : 175)
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

                    // 3-DoF Spatial Anchor Mode & Head Tracking Source Controls
                    VStack(spacing: 8) {
                        HStack {
                            Text("3D Spatial Mode")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Picker("3D Spatial Mode", selection: $xreal.spatialMode) {
                                ForEach(XRealSpatialAnchorMode.allCases) { sm in
                                    Text(sm.rawValue).tag(sm)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Head Tracker")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Picker("Head Tracker", selection: $xreal.trackingSource) {
                                ForEach(XRealHeadTrackingSource.allCases) { ts in
                                    Text(ts.rawValue).tag(ts)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack(spacing: 8) {
                            Text("Head Pan Speed")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                            Slider(value: $xreal.spatialSensitivity, in: 6.0...30.0)
                                .tint(xreal.palette.primary)
                        }
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

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
                                        .stroke(listener.isRecording ? Theme.danger : xreal.palette.primary.opacity(0.45), lineWidth: 1.5)
                                )

                            VStack(spacing: 6) {
                                Image(systemName: listener.isRecording ? "waveform.circle.fill" : "hand.point.up.braille.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(listener.isRecording ? Theme.danger : xreal.palette.primary)
                                Text(listener.isRecording ? "LISTENING… DOUBLE-TAP OR TAP BUTTON TO SEND" : "EYES-FREE AR TRACKPAD")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                Text("Slide thumb to aim reticle · Double-tap to speak · Triple-tap to recenter 0°")
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
                            TapGesture(count: 3).onEnded {
                                xreal.recenterHUD()
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
                            Label(listener.isRecording ? "Send Voice" : "Talk to Jarvis",
                                  systemImage: listener.isRecording ? "stop.circle.fill" : "mic.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(listener.isRecording ? Theme.danger : xreal.palette.primary)

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
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("J.A.R.V.I.S. // 3-DOF XREAL")
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
                xreal.onGazeCommandTriggered = { prompt in
                    sendToJarvis(prompt)
                }
                xreal.checkScreens()
                await telemetry.refreshAll()
            }
        }
    }

    private func toggleVoice() {
        if listener.isRecording {
            let spoken = listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            xreal.liveTranscript = ""
            guard !spoken.isEmpty else { return }
            sendToJarvis(spoken)
        } else {
            speaker.stop()
            if music.isPlaying { music.pause() }
            Task { await listener.start() }
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
