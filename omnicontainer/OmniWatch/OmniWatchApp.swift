import SwiftUI
import WatchKit
import UIKit
import AVFoundation
import HealthKit
import Foundation

@main
struct OmniWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WristOSRootView()
        }
    }
}

struct WatchCameraEvent: Identifiable {
    let id: String
    let camera: String
    let label: String
    let score: Int
}

@MainActor
final class WristOSStore: ObservableObject {
    @Published var truenasHost: String = "100.85.127.42"
    @Published var workPCHost: String = "100.102.4.54"
    @Published var bazziteHost: String = "100.79.246.119"
    @Published var laurenHost: String = "100.116.230.25"

    // Watch Face selector (0..4)
    @Published var selectedFaceIndex: Double = 0.0
    @Published var statusLine: String = "J.A.R.V.I.S. WRIST OS READY"
    @Published var jarvisReply: String = "All TrueNAS, SentryCam, Work PC, and Bazzite systems standing by, sir."
    @Published var voiceInputText: String = ""
    @Published var isBusy: Bool = false

    // Telemetry & Biometrics
    @Published var heartRateBPM: Int = 72
    @Published var stepCount: Int = 4280
    @Published var batteryPercent: Int = 88
    @Published var serverLoadPercent: Int = 24
    @Published var activeContainers: Int = 26
    @Published var nextPaydayDays: Int = 11
    @Published var workPCOnline: Bool = true
    @Published var bazziteOnline: Bool = false
    @Published var ghostModeActive: Bool = false

    // SentryCam Live & PTZ
    @Published var selectedCamera: String = "tapo_c200"
    @Published var cameraFrames: [String: UIImage] = [:]
    @Published var recentEvents: [WatchCameraEvent] = []
    @Published var crownPanValue: Double = 0.15
    @Published var crownVolumeValue: Double = 50.0
    @Published var lastCrownVolStep: Int = 50
    @Published var windowsPin: String = UserDefaults.standard.string(forKey: "watch_win_pin") ?? ""

    private var audioPlayer: AVAudioPlayer?
    private let healthStore = HKHealthStore()

    let faceNames = [
        "STARK ARC HUD",
        "007 Q-BRANCH",
        "PIP-BOY 3000",
        "NIGHT-OPS CCTV",
        "LCARS CHRONO"
    ]

    init() {
        updateBattery()
        requestHealthKit()
    }

    func playHaptic(_ type: WKHapticType = .click) {
        WKInterfaceDevice.current().play(type)
    }

    func updateBattery() {
        let dev = WKInterfaceDevice.current()
        dev.isBatteryMonitoringEnabled = true
        let lvl = dev.batteryLevel
        if lvl >= 0 {
            batteryPercent = Int(lvl * 100)
        }
    }

    func requestHealthKit() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return }
        healthStore.requestAuthorization(toShare: [], read: [hrType, stepType]) { [weak self] ok, _ in
            if ok {
                Task { @MainActor in
                    self?.fetchLatestHeartRate()
                }
            }
        }
    }

    func fetchLatestHeartRate() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let q = HKSampleQuery(sampleType: hrType, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            if let s = samples?.first as? HKQuantitySample {
                let bpm = Int(s.quantity.doubleValue(for: HKUnit(from: "count/min")))
                Task { @MainActor in
                    self?.heartRateBPM = bpm
                }
            }
        }
        healthStore.execute(q)
    }

    // MARK: - Work PC & Bazzite Unlockers
    func unlockWorkPC() async {
        playHaptic(.notification)
        statusLine = "Unlocking Work PC..."
        let pinParam = windowsPin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let u1 = URL(string: "http://\(workPCHost):9090/api/power/unlock?pin=\(pinParam)")
        let u2 = URL(string: "http://\(workPCHost):9095/wake")

        var ok = false
        if let u1 = u1 {
            var req = URLRequest(url: u1)
            req.timeoutInterval = 5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                ok = true
            }
        }
        if let u2 = u2 {
            var req = URLRequest(url: u2)
            req.timeoutInterval = 3
            _ = try? await URLSession.shared.data(for: req)
        }
        playHaptic(ok ? .success : .retry)
        statusLine = ok ? "🔓 Work PC Unlocked!" : "🔓 Wake+Unlock Sent to Work PC"
    }

    func lockWorkPC(blankOnly: Bool = false) async {
        playHaptic(.directionDown)
        let mode = blankOnly ? "blank" : "winlock"
        guard let u = URL(string: "http://\(workPCHost):9090/api/power/lock?mode=\(mode)") else { return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 4
        _ = try? await URLSession.shared.data(for: req)
        statusLine = blankOnly ? "Monitors Blanked" : "🔒 Work PC Locked"
    }

    func unlockBazzitePC() async {
        playHaptic(.notification)
        statusLine = "Waking & Unlocking Bazzite..."
        let unlockCmd = "loginctl unlock-sessions; for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do loginctl unlock-session $s; done; DISPLAY=:0 xset dpms force on 2>/dev/null; qdbus org.freedesktop.ScreenSaver /ScreenSaver SetActive false 2>/dev/null; dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call /ScreenSaver org.freedesktop.ScreenSaver.SetActive boolean:false 2>/dev/null; kscreen-doctor --dpms on 2>/dev/null; echo 'Unlocked'"

        var directOK = false
        if let bzURL = URL(string: "http://\(bazziteHost):9091/api/antigravity/exec") {
            var req = URLRequest(url: bzURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 4
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": unlockCmd, "timeout": 6])
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                directOK = true
            }
        }

        // Also trigger WOL + Unlock relay via Work PC Bridge & TrueNAS
        if let wURL = URL(string: "http://\(workPCHost):9090/api/power/bazzite/unlock") {
            var req = URLRequest(url: wURL)
            req.timeoutInterval = 4
            _ = try? await URLSession.shared.data(for: req)
        }
        if let tnURL = URL(string: "http://\(truenasHost):9092/api/antigravity/exec") {
            var req = URLRequest(url: tnURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 4
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let relayCmd = "curl -s -m 3 -X POST http://\(bazziteHost):9091/api/antigravity/exec -H 'Content-Type: application/json' -d '{\"command\":\"loginctl unlock-sessions; DISPLAY=:0 xset dpms force on 2>/dev/null\"}' >/dev/null 2>&1 &"
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": relayCmd])
            _ = try? await URLSession.shared.data(for: req)
        }

        playHaptic(.success)
        statusLine = directOK ? "🔓 Bazzite Unlocked!" : "⚡ Bazzite WOL + Unlock Sent!"
    }

    func lockBazzitePC() async {
        playHaptic(.directionDown)
        if let wURL = URL(string: "http://\(workPCHost):9090/api/power/bazzite/lock") {
            _ = try? await URLSession.shared.data(from: wURL)
        }
        statusLine = "🔒 Bazzite Locked"
    }

    func unlockLaurenPC() async {
        playHaptic(.success)
        if let u = URL(string: "http://\(workPCHost):9090/api/power/lauren/unlock") {
            _ = try? await URLSession.shared.data(from: u)
        }
        statusLine = "🔓 Lauren PC Unlocked"
    }

    func toggleAniimoGhost() async {
        playHaptic(.click)
        guard let u = URL(string: "http://\(workPCHost):9095/ghost/toggle") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: u),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let g = json["ghost"] as? Bool {
            ghostModeActive = g
            statusLine = g ? "👻 Aniimo Ghost ON" : "🎮 Aniimo Foreground"
        } else {
            statusLine = "Ghost toggle sent"
        }
    }

    func adjustPCVolume(newVal: Double) async {
        let cur = Int(newVal)
        let diff = cur - lastCrownVolStep
        guard abs(diff) >= 2 else { return }
        lastCrownVolStep = cur
        playHaptic(.click)
        let delta = diff > 0 ? 2 : -2
        guard let u = URL(string: "http://\(workPCHost):9090/api/volume?delta=\(delta)") else { return }
        _ = try? await URLSession.shared.data(from: u)
        statusLine = "PC Volume \(delta > 0 ? "▲" : "▼") (\(cur)%)"
    }

    // MARK: - J.A.R.V.I.S. Voice & Chat
    func askJarvis(_ prompt: String) async {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        playHaptic(.start)
        isBusy = true
        statusLine = "Consulting J.A.R.V.I.S..."
        defer { isBusy = false }

        let enriched = "\(q) [Watch Telemetry: HR \(heartRateBPM) BPM, Battery \(batteryPercent)%]"
        guard let u = URL(string: "http://\(truenasHost):8998/api/voice/ask") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 18
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": enriched])

        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reply = (json["reply"] as? String) ?? "Command executed, sir."
            jarvisReply = reply
            statusLine = "J.A.R.V.I.S. Responded"
            playHaptic(.success)
            if let b64 = json["audio_base64"] as? String,
               let wavData = Data(base64Encoded: b64) {
                playWatchAudio(wavData)
            }
            return
        }

        // Fallback to Work PC Bridge
        if let u2 = URL(string: "http://\(workPCHost):9090/api/chat") {
            var req2 = URLRequest(url: u2)
            req2.httpMethod = "POST"
            req2.timeoutInterval = 10
            req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req2.httpBody = try? JSONSerialization.data(withJSONObject: ["message": q])
            if let (d2, _) = try? await URLSession.shared.data(for: req2),
               let j2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
               let r2 = j2["reply"] as? String {
                jarvisReply = r2
                statusLine = "J.A.R.V.I.S. Bridge Reply"
                playHaptic(.success)
                return
            }
        }
        statusLine = "Command Dispatched"
    }

    private func playWatchAudio(_ data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            // Audio fallback silent
        }
    }

    // MARK: - SentryCam Live Snapshot & Crown PTZ
    func refreshCameraSnapshot(_ cam: String? = nil) async {
        let targetCam = cam ?? selectedCamera
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "http://\(truenasHost):5000/api/\(targetCam)/latest.jpg?h=360&t=\(ts)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let img = UIImage(data: data) {
            cameraFrames[targetCam] = img
        }
    }

    func loadRecentEvents() async {
        guard let url = URL(string: "http://\(truenasHost):5000/api/events?limit=8") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var out: [WatchCameraEvent] = []
            for item in arr {
                if let id = item["id"] as? String {
                    let c = (item["camera"] as? String) ?? "cam"
                    let l = (item["label"] as? String) ?? "motion"
                    let sc = Int(((item["top_score"] as? Double) ?? 0.85) * 100)
                    out.append(WatchCameraEvent(id: id, camera: c, label: l, score: sc))
                }
            }
            recentEvents = out
        }
    }

    func toggleTapoPatrol(start: Bool) async {
        playHaptic(.click)
        let cmd = start ? "docker start tapo-patrol" : "docker stop tapo-patrol"
        guard let u = URL(string: "http://\(truenasHost):9092/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        _ = try? await URLSession.shared.data(for: req)
        statusLine = start ? "Tapo Patrol Active" : "Tapo Patrol Paused"
    }
}

struct WristOSRootView: View {
    @StateObject private var store = WristOSStore()

    var body: some View {
        TabView {
            WatchFacesGalleryView(store: store)
            WatchUnlockDeckView(store: store)
            WatchJarvisVoiceView(store: store)
            WatchSentryCamView(store: store)
            WatchOpsTelemetryView(store: store)
        }
        .background(Color.black)
    }
}

// MARK: - 1. 5 Interactive Watch Faces (Digital Crown Switchable)
struct WatchFacesGalleryView: View {
    @ObservedObject var store: WristOSStore
    @Environment(\.isLuminanceReduced) var isLuminanceReduced

    var activeIndex: Int {
        min(max(Int(store.selectedFaceIndex.rounded()), 0), store.faceNames.count - 1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 15.0 : 1.0)) { context in
            ZStack {
                Color.black.ignoresSafeArea()

                switch activeIndex {
                case 0:
                    StarkArcWatchFace(date: context.date, store: store, dim: isLuminanceReduced)
                case 1:
                    GoldenEyeWatchFace(date: context.date, store: store, dim: isLuminanceReduced)
                case 2:
                    PipBoyWatchFace(date: context.date, store: store, dim: isLuminanceReduced)
                case 3:
                    NightOpsCCTVWatchFace(date: context.date, store: store, dim: isLuminanceReduced)
                default:
                    LCARSChronoWatchFace(date: context.date, store: store, dim: isLuminanceReduced)
                }

                VStack {
                    HStack {
                        Text(store.faceNames[activeIndex])
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                            .onTapGesture {
                                store.playHaptic(.click)
                                store.selectedFaceIndex = Double((activeIndex + 1) % store.faceNames.count)
                            }
                        Spacer()
                        Text("♥ \(store.heartRateBPM)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 6)
                    Spacer()

                    if !isLuminanceReduced {
                        HStack(spacing: 6) {
                            Button {
                                Task { await store.unlockWorkPC() }
                            } label: {
                                Label("Work PC", systemImage: "lock.open.desktopcomputer")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(Color.cyan.opacity(0.25))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { await store.unlockBazzitePC() }
                            } label: {
                                Label("Bazzite", systemImage: "gamecontroller.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(Color.purple.opacity(0.3))
                                    .foregroundColor(.purple)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .focusable(true)
        .digitalCrownRotation(
            $store.selectedFaceIndex,
            from: 0.0,
            through: Double(store.faceNames.count - 1),
            by: 1.0,
            sensitivity: .low,
            isContinuous: true,
            isHapticFeedbackEnabled: true
        )
    }
}

struct StarkArcWatchFace: View {
    let date: Date
    @ObservedObject var store: WristOSStore
    let dim: Bool

    var secAngle: Double {
        Double(Calendar.current.component(.second, from: date)) * 6.0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.cyan.opacity(dim ? 0.2 : 0.35), style: StrokeStyle(lineWidth: 4, dash: [8, 6]))
                .frame(width: 138, height: 138)
                .rotationEffect(.degrees(secAngle))

            Circle()
                .stroke(Color.blue.opacity(dim ? 0.2 : 0.5), style: StrokeStyle(lineWidth: 2, dash: [4, 8]))
                .frame(width: 112, height: 112)
                .rotationEffect(.degrees(-secAngle * 1.5))

            Circle()
                .fill(RadialGradient(colors: [.cyan.opacity(dim ? 0.15 : 0.45), .clear], center: .center, startRadius: 4, endRadius: 55))
                .frame(width: 100, height: 100)

            VStack(spacing: 1) {
                Text(date, style: .time)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                Text(store.statusLine)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .onTapGesture {
                Task { await store.askJarvis("Give me a quick status report") }
            }
        }
    }
}

struct GoldenEyeWatchFace: View {
    let date: Date
    @ObservedObject var store: WristOSStore
    let dim: Bool

    var body: some View {
        HStack {
            // Left Health Bar (Battery %)
            VStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill((8 - i) * 12 <= store.batteryPercent ? Color.orange : Color.white.opacity(0.1))
                        .frame(width: 10, height: 11)
                }
            }
            Spacer()
            VStack(spacing: 3) {
                Text("007 // Q-BRANCH")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                Text(date, style: .time)
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text("BAT \(store.batteryPercent)% • NAS OK")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                Text(store.statusLine)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
            Spacer()
            // Right Armor Bar (TrueNAS / PC Health)
            VStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i > 0 ? Color.cyan : Color.white.opacity(0.1))
                        .frame(width: 10, height: 11)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

struct PipBoyWatchFace: View {
    let date: Date
    @ObservedObject var store: WristOSStore
    let dim: Bool
    let pipGreen = Color(red: 0.1, green: 1.0, blue: 0.45)

    var body: some View {
        VStack(spacing: 3) {
            Text("PIP-BOY 3000 MK IV")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(pipGreen)
            Divider().background(pipGreen)
            Text(date, style: .time)
                .font(.system(size: 25, weight: .bold, design: .monospaced))
                .foregroundColor(pipGreen)
            HStack(spacing: 8) {
                Text("HP \(store.batteryPercent)/100")
                Text("BPM \(store.heartRateBPM)")
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(pipGreen)
            Text(store.statusLine)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(pipGreen.opacity(0.8))
                .lineLimit(1)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pipGreen.opacity(0.6), lineWidth: 1.5))
    }
}

struct NightOpsCCTVWatchFace: View {
    let date: Date
    @ObservedObject var store: WristOSStore
    let dim: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(date, style: .time)
                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                .foregroundColor(.red)
            if let img = store.cameraFrames["tapo_c200"] {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 78)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.6), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.12))
                    .frame(height: 78)
                    .overlay(Text("TAPO C200 LIVE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.red))
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshCameraSnapshot("tapo_c200")
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }
}

struct LCARSChronoWatchFace: View {
    let date: Date
    @ObservedObject var store: WristOSStore
    let dim: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange)
                    .frame(width: 28, height: 14)
                Text("LCARS // STARDATE")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(.orange)
            }
            Text(date, style: .time)
                .font(.system(size: 24, weight: .black, design: .monospaced))
                .foregroundColor(.yellow)
            HStack(spacing: 6) {
                Text("DOCKER: \(store.activeContainers)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                Text("PAYDAY: \(store.nextPaydayDays)D")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - 2. Wrist PC Unlock & DeskSwitch Deck
struct WatchUnlockDeckView: View {
    @ObservedObject var store: WristOSStore

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("WRIST PC UNLOCKER")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(.cyan)

                Text(store.statusLine)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)

                // Work PC Unlock & Lock
                VStack(spacing: 5) {
                    Text("Work PC (ROSS-DYMOND-PC)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 6) {
                        Button {
                            Task { await store.unlockWorkPC() }
                        } label: {
                            Label("Unlock", systemImage: "lock.open.fill")
                                .font(.system(size: 11, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.cyan)

                        Button {
                            Task { await store.lockWorkPC(blankOnly: false) }
                        } label: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .tint(.red)
                    }
                }
                .padding(6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)

                // Bazzite Linux PC Unlock & Lock
                VStack(spacing: 5) {
                    Text("Bazzite Gaming PC")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 6) {
                        Button {
                            Task { await store.unlockBazzitePC() }
                        } label: {
                            Label("Unlock + WOL", systemImage: "lock.open.fill")
                                .font(.system(size: 11, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.purple)

                        Button {
                            Task { await store.lockBazzitePC() }
                        } label: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .tint(.orange)
                    }
                }
                .padding(6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)

                // Aniimo Ghost Mode & Lauren PC
                HStack(spacing: 6) {
                    Button {
                        Task { await store.toggleAniimoGhost() }
                    } label: {
                        Label("Ghost", systemImage: "eye.slash.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .tint(.green)

                    Button {
                        Task { await store.unlockLaurenPC() }
                    } label: {
                        Label("Lauren", systemImage: "tv.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .tint(.pink)
                }

                // Optional Windows PIN input for hard lock screen
                TextField("Work PC PIN (Optional)", text: $store.windowsPin)
                    .font(.system(size: 10))
                    .onChange(of: store.windowsPin) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: "watch_win_pin")
                    }

                Text("Crown: Work PC Volume (\(Int(store.crownVolumeValue))%)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 4)
        }
        .focusable(true)
        .digitalCrownRotation(
            $store.crownVolumeValue,
            from: 0.0,
            through: 100.0,
            by: 2.0,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: store.crownVolumeValue) { _, newVal in
            Task { await store.adjustPCVolume(newVal: newVal) }
        }
    }
}

// MARK: - 3. J.A.R.V.I.S. Wrist Voice & AI
struct WatchJarvisVoiceView: View {
    @ObservedObject var store: WristOSStore

    let presets = [
        ("Status Report", "Status report please Jarvis"),
        ("Check Cameras", "Check the security cameras"),
        ("Unlock Work PC", "Unlock my work PC"),
        ("Switch to TV", "Switch display to TV")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Circle().fill(store.isBusy ? Color.orange : Color.cyan).frame(width: 8, height: 8)
                    Text("J.A.R.V.I.S. VOICE CORE")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.cyan)
                }

                Text(store.jarvisReply)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cyan.opacity(0.14))
                    .cornerRadius(8)

                TextField("Speak to J.A.R.V.I.S...", text: $store.voiceInputText)
                    .submitLabel(.send)
                    .onSubmit {
                        let q = store.voiceInputText
                        store.voiceInputText = ""
                        Task { await store.askJarvis(q) }
                    }

                ForEach(presets, id: \.0) { p in
                    Button {
                        Task { await store.askJarvis(p.1) }
                    } label: {
                        Text(p.0)
                            .font(.system(size: 10, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - 4. SentryCam Wrist CCTV + Digital Crown PTZ
struct WatchSentryCamView: View {
    @ObservedObject var store: WristOSStore

    let cams = [
        ("tapo_c200", "Tapo C200"),
        ("bike_camera", "Bike Cam"),
        ("doorbell", "Doorbell")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(cams, id: \.0) { c in
                        Button {
                            store.selectedCamera = c.0
                            Task { await store.refreshCameraSnapshot(c.0) }
                        } label: {
                            Text(c.1)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity)
                                .background(store.selectedCamera == c.0 ? Color.red : Color.white.opacity(0.12))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let img = store.cameraFrames[store.selectedCamera] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 96)
                        .overlay(ProgressView().tint(.red))
                }

                HStack(spacing: 6) {
                    Button("Patrol ON") {
                        Task { await store.toggleTapoPatrol(start: true) }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .tint(.green)

                    Button("Pause") {
                        Task { await store.toggleTapoPatrol(start: false) }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .tint(.orange)
                }

                if !store.recentEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RECENT AI DETECTIONS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                        ForEach(store.recentEvents.prefix(4)) { ev in
                            Text("• \(ev.label.capitalized) (\(ev.camera)) \(ev.score)%")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .task(id: store.selectedCamera) {
            await store.loadRecentEvents()
            while !Task.isCancelled {
                await store.refreshCameraSnapshot()
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }
        }
    }
}

// MARK: - 5. TrueNAS, Docker & Biometrics Telemetry
struct WatchOpsTelemetryView: View {
    @ObservedObject var store: WristOSStore

    let containers = ["frigate", "tapo-patrol", "icloudpd", "ix-jellyfin-jellyfin-1"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("OPS & BIOMETRICS")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(.green)

                HStack {
                    Text("♥ \(store.heartRateBPM) BPM")
                        .foregroundColor(.red)
                    Spacer()
                    Text("⚡ \(store.batteryPercent)%")
                        .foregroundColor(.green)
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))

                Text("DOCKER QUICK RESTART")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)

                ForEach(containers, id: \.self) { c in
                    Button {
                        store.playHaptic(.click)
                        Task {
                            guard let u = URL(string: "http://\(store.truenasHost):9092/api/antigravity/exec") else { return }
                            var req = URLRequest(url: u)
                            req.httpMethod = "POST"
                            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": "docker restart \(c)"])
                            _ = try? await URLSession.shared.data(for: req)
                            store.statusLine = "Restarted \(c)"
                        }
                    } label: {
                        HStack {
                            Text(c)
                                .font(.system(size: 10, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                        }
                    }
                    .tint(.teal)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
