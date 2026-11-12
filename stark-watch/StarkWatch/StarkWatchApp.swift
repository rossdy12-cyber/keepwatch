import SwiftUI
import WatchKit
import HealthKit
import Foundation

// Stark Face — a watch-only app that looks like a watch face and pulls live status from the
// Stark Store apps (NAS Command, SentryCam, Nocturne, GlucoPulse/Health, Paydays, J.A.R.V.I.S.).
// Its complications (StarkWatchWidgets) put the same data on a real Apple watch face.

@main
struct StarkWatchApp: App {
    @StateObject private var store = StarkStore()
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}

// MARK: - Theme

enum Stark {
    static let crimson = Color(red: 0.75, green: 0.06, blue: 0.19)
    static let rose = Color(red: 0.91, green: 0.25, blue: 0.36)
    static let panel = Color(red: 0.10, green: 0.04, blue: 0.05)
    static let text = Color(red: 0.94, green: 0.90, blue: 0.91)
    static let muted = Color(red: 0.60, green: 0.51, blue: 0.53)
    static let ok = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.25)
}

enum Page: String, Hashable { case face, nas, cams, messages, jarvis, settings }

// MARK: - Store

struct CamEvent: Identifiable {
    let id: String
    let camera: String
    let label: String
    let time: Date
}

struct ChatMessage: Identifiable {
    let id: Int
    let sender: String
    let text: String
}

@MainActor
final class StarkStore: ObservableObject {
    private let d = UserDefaults.standard

    // Settings (persisted)
    @Published var nasHost: String { didSet { d.set(nasHost, forKey: "nasHost") } }
    @Published var relayURL: String { didSet { d.set(relayURL, forKey: "relayURL") } }
    @Published var relayToken: String { didSet { d.set(relayToken, forKey: "relayToken") } }
    @Published var relayRoom: String { didSet { d.set(relayRoom, forKey: "relayRoom") } }
    @Published var myName: String { didSet { d.set(myName, forKey: "myName") } }
    @Published var payAnchor: Date { didSet { d.set(payAnchor.timeIntervalSince1970, forKey: "payAnchor") } }
    @Published var payEveryDays: Int { didSet { d.set(payEveryDays, forKey: "payEveryDays") } }   // 0 = monthly
    @Published var lastReadID: Int { didSet { d.set(lastReadID, forKey: "lastReadID") } }

    // Live data (nil = not known yet / unavailable)
    @Published var page: Page = .face
    @Published var nasHealthy: Bool?
    @Published var nasDetail = "Not checked yet"
    @Published var containersRunning: Int?
    @Published var containersTotal: Int?
    @Published var events: [CamEvent] = []
    @Published var messages: [ChatMessage] = []
    @Published var glucose: Double?          // mmol/L
    @Published var glucoseDelta: Double?     // change vs the previous reading
    @Published var glucoseTime: Date?
    @Published var heartRate: Int?
    @Published var battery: Int?
    @Published var jarvisReply = ""
    @Published var busy = false
    @Published var lastRefresh: Date?

    private let health = HKHealthStore()
    private var session: WKExtendedRuntimeSession?

    init() {
        nasHost = d.string(forKey: "nasHost") ?? "100.85.127.42"
        relayURL = d.string(forKey: "relayURL") ?? ""
        relayToken = d.string(forKey: "relayToken") ?? ""
        relayRoom = d.string(forKey: "relayRoom") ?? "home"
        myName = d.string(forKey: "myName") ?? "Ross"
        let anchor = d.double(forKey: "payAnchor")
        payAnchor = anchor > 0 ? Date(timeIntervalSince1970: anchor) : Date()
        payEveryDays = d.object(forKey: "payEveryDays") as? Int ?? 0
        lastReadID = d.integer(forKey: "lastReadID")
        requestHealth()
    }

    var unread: Int { messages.filter { $0.id > lastReadID && $0.sender != myName }.count }
    var lastEvent: CamEvent? { events.first }

    /// Days until the next payday, from the anchor date and frequency set in Settings.
    var daysToPayday: Int? {
        guard d.double(forKey: "payAnchor") > 0 else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var next = cal.startOfDay(for: payAnchor)
        var guardCount = 0
        while next < today && guardCount < 2000 {
            if payEveryDays > 0 { next = cal.date(byAdding: .day, value: payEveryDays, to: next) ?? today }
            else { next = cal.date(byAdding: .month, value: 1, to: next) ?? today }
            guardCount += 1
        }
        return cal.dateComponents([.day], from: today, to: next).day
    }

    // MARK: session (keeps the face on screen for longer than a normal app)

    func startSession() {
        guard session == nil || session?.state == .invalid else { return }
        let s = WKExtendedRuntimeSession()
        s.start()
        session = s
    }

    // MARK: refresh

    func refreshAll() async {
        let dev = WKInterfaceDevice.current()
        dev.isBatteryMonitoringEnabled = true
        if dev.batteryLevel >= 0 { battery = Int(dev.batteryLevel * 100) }
        async let a: Void = refreshNAS()
        async let b: Void = refreshEvents()
        async let c: Void = refreshMessages()
        _ = await (a, b, c)
        fetchHealth()
        lastRefresh = Date()
    }

    private func exec(_ command: String, timeout: TimeInterval = 10) async -> String? {
        guard let u = URL(string: "http://\(nasHost):9092/api/antigravity/exec") else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": command])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? ""
    }

    func refreshNAS() async {
        let cmd = "zpool status -x 2>&1 | head -n 3; echo '@@'; docker ps -q 2>/dev/null | wc -l; echo '@@'; docker ps -aq 2>/dev/null | wc -l"
        guard let out = await exec(cmd) else {
            nasHealthy = nil; nasDetail = "NAS unreachable"; return
        }
        let parts = out.components(separatedBy: "@@").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pool = parts.first ?? ""
        nasHealthy = pool.contains("all pools are healthy")
        nasDetail = pool.isEmpty ? "No pool status returned" : pool
        containersRunning = parts.count > 1 ? Int(parts[1]) : nil
        containersTotal = parts.count > 2 ? Int(parts[2]) : nil
    }

    func refreshEvents() async {
        guard let u = URL(string: "http://\(nasHost):5000/api/events?limit=8&include_thumbnails=0") else { return }
        var req = URLRequest(url: u); req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        events = arr.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            return CamEvent(id: id,
                            camera: (e["camera"] as? String) ?? "camera",
                            label: (e["label"] as? String) ?? "motion",
                            time: Date(timeIntervalSince1970: (e["start_time"] as? Double) ?? 0))
        }
    }

    func refreshMessages() async {
        let base = relayURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty,
              let room = relayRoom.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(base)/api/relay/messages?room=\(room)&since=\(max(lastReadID - 20, 0))") else { return }
        var req = URLRequest(url: u); req.timeoutInterval = 10
        if !relayToken.isEmpty { req.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        messages = arr.compactMap { m in
            guard let id = m["id"] as? Int else { return nil }
            return ChatMessage(id: id, sender: (m["sender"] as? String) ?? "?", text: (m["text"] as? String) ?? "")
        }
    }

    func markRead() { if let top = messages.map(\.id).max(), top > lastReadID { lastReadID = top } }

    func send(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: "\(relayURL)/api/relay/send") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"; req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !relayToken.isEmpty { req.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["room": relayRoom, "sender": myName, "text": t])
        _ = try? await URLSession.shared.data(for: req)
        await refreshMessages()
        markRead()
    }

    func askJarvis(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let u = URL(string: "http://\(nasHost):8998/api/voice/ask") else { return }
        busy = true; defer { busy = false }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"; req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": q])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = obj["reply"] as? String {
            jarvisReply = reply
            WKInterfaceDevice.current().play(.success)
        } else {
            jarvisReply = "Couldn't reach J.A.R.V.I.S."
            WKInterfaceDevice.current().play(.failure)
        }
    }

    // MARK: Health (glucose + heart rate). Needs the HealthKit entitlement in the signing profile;
    // without it the request fails quietly and the tiles show a dash.

    private var glucoseType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .bloodGlucose) }
    private var heartType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .heartRate) }

    func requestHealth() {
        guard HKHealthStore.isHealthDataAvailable(), let g = glucoseType, let h = heartType else { return }
        health.requestAuthorization(toShare: [], read: [g, h]) { [weak self] _, _ in
            Task { @MainActor in self?.fetchHealth() }
        }
    }

    func fetchHealth() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        if let g = glucoseType {
            let q = HKSampleQuery(sampleType: g, predicate: nil, limit: 2, sortDescriptors: sort) { [weak self] _, samples, _ in
                let unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
                let vals = (samples as? [HKQuantitySample]) ?? []
                guard let latest = vals.first else { return }
                let v = latest.quantity.doubleValue(for: unit)
                let prev = vals.count > 1 ? vals[1].quantity.doubleValue(for: unit) : nil
                let when = latest.endDate
                Task { @MainActor in
                    self?.glucose = v
                    self?.glucoseDelta = prev.map { v - $0 }
                    self?.glucoseTime = when
                }
            }
            health.execute(q)
        }
        if let h = heartType {
            let q = HKSampleQuery(sampleType: h, predicate: nil, limit: 1, sortDescriptors: sort) { [weak self] _, samples, _ in
                guard let s = samples?.first as? HKQuantitySample else { return }
                let bpm = Int(s.quantity.doubleValue(for: HKUnit(from: "count/min")))
                Task { @MainActor in self?.heartRate = bpm }
            }
            health.execute(q)
        }
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var store: StarkStore
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $store.page) {
            FaceView(store: store).tag(Page.face)
            NASView(store: store).tag(Page.nas)
            CamsView(store: store).tag(Page.cams)
            MessagesView(store: store).tag(Page.messages)
            JarvisView(store: store).tag(Page.jarvis)
            SettingsView(store: store).tag(Page.settings)
        }
        .tabViewStyle(.verticalPage)
        .background(Color.black)
        .tint(Stark.rose)
        .task {
            store.startSession()
            while !Task.isCancelled {
                await store.refreshAll()
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            }
        }
        .onChange(of: phase) { _, p in
            if p == .active { store.startSession(); Task { await store.refreshAll() } }
        }
        // Complications open the matching page: starkface://nas, starkface://cams, ...
        .onOpenURL { url in
            if let host = url.host, let p = Page(rawValue: host) { store.page = p }
        }
    }
}

// MARK: - The face

struct FaceView: View {
    @ObservedObject var store: StarkStore
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        TimelineView(.periodic(from: .now, by: dim ? 60 : 1)) { ctx in
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Stark.rose)
                        .textCase(.uppercase)
                    Spacer()
                    if let b = store.battery {
                        Text("\(b)%").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Stark.muted)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(dim ? Stark.crimson : Stark.text)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    if !dim {
                        Text(ctx.date, format: .dateTime.second(.twoDigits))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Stark.crimson)
                            .monospacedDigit()
                    }
                    Spacer()
                }
                .frame(height: 46)

                Rectangle().fill(Stark.crimson.opacity(dim ? 0.3 : 0.8)).frame(height: 1)

                if !dim {
                    HStack(spacing: 4) {
                        tile("drop.fill", glucoseText, glucoseSub, glucoseColor) { }
                        tile("externaldrive.fill", nasText, nasSub, nasColor) { store.page = .nas }
                    }
                    HStack(spacing: 4) {
                        tile("video.fill", camText, camSub, Stark.rose) { store.page = .cams }
                        tile("bubble.left.fill", msgText, "Nocturne", store.unread > 0 ? Stark.warn : Stark.muted) { store.page = .messages }
                    }
                    HStack(spacing: 4) {
                        tile("sterlingsign.circle.fill", payText, "payday", Stark.rose) { }
                        tile("waveform", "Jarvis", heartText, Stark.crimson) { store.page = .jarvis }
                    }
                } else {
                    // Always-on: keep it sparse and dark.
                    Text(dimSummary)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Stark.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func tile(_ icon: String, _ value: String, _ sub: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Stark.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text(sub).font(.system(size: 8, weight: .medium)).foregroundStyle(Stark.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7).fill(Stark.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Stark.crimson.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var glucoseText: String {
        guard let g = store.glucose else { return "—" }
        let arrow: String
        if let dlt = store.glucoseDelta { arrow = dlt > 0.3 ? " ↑" : (dlt < -0.3 ? " ↓" : " →") } else { arrow = "" }
        return String(format: "%.1f", g) + arrow
    }
    private var glucoseSub: String {
        guard let t = store.glucoseTime else { return "glucose" }
        let mins = Int(Date().timeIntervalSince(t) / 60)
        return mins < 60 ? "mmol/L · \(mins)m" : "mmol/L · \(mins / 60)h ago"
    }
    private var glucoseColor: Color {
        guard let g = store.glucose else { return Stark.muted }
        return (g < 4.0 || g > 10.0) ? Stark.warn : Stark.ok
    }
    private var nasText: String {
        switch store.nasHealthy { case .some(true): return "NAS OK"; case .some(false): return "NAS alert"; case .none: return "NAS —" }
    }
    private var nasSub: String {
        if let r = store.containersRunning, let t = store.containersTotal { return "\(r)/\(t) apps up" }
        return "pools"
    }
    private var nasColor: Color {
        switch store.nasHealthy { case .some(true): return Stark.ok; case .some(false): return Stark.warn; case .none: return Stark.muted }
    }
    private var camText: String { store.lastEvent.map { $0.label.capitalized } ?? "—" }
    private var camSub: String {
        guard let e = store.lastEvent else { return "cameras" }
        return "\(e.camera) · \(ago(e.time))"
    }
    private var msgText: String { store.relayURL.isEmpty ? "Set up" : (store.unread > 0 ? "\(store.unread) new" : "No new") }
    private var payText: String {
        guard let dys = store.daysToPayday else { return "Set date" }
        return dys == 0 ? "Today" : "\(dys) day\(dys == 1 ? "" : "s")"
    }
    private var heartText: String { store.heartRate.map { "♥ \($0)" } ?? "ask" }
    private var dimSummary: String {
        var bits: [String] = []
        if let g = store.glucose { bits.append(String(format: "%.1f", g)) }
        if store.nasHealthy == false { bits.append("NAS alert") }
        if store.unread > 0 { bits.append("\(store.unread) msg") }
        return bits.joined(separator: "  ·  ")
    }
}

func ago(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

// MARK: - Detail pages

struct PageHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(Stark.rose)
            .textCase(.uppercase).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NASView: View {
    @ObservedObject var store: StarkStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageHeader(title: "NAS Command")
                HStack {
                    Image(systemName: store.nasHealthy == true ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.nasHealthy == true ? Stark.ok : Stark.warn)
                    Text(store.nasHealthy == true ? "Pools healthy" : (store.nasHealthy == false ? "Pool problem" : "Unknown"))
                        .font(.system(size: 14, weight: .bold))
                }
                if let r = store.containersRunning, let t = store.containersTotal {
                    Text("\(r) of \(t) containers running").font(.system(size: 12)).foregroundStyle(Stark.text)
                }
                Text(store.nasDetail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Stark.muted)
                Button("Refresh") { Task { await store.refreshNAS() } }
                if let t = store.lastRefresh {
                    Text("Updated \(ago(t)) ago").font(.system(size: 9)).foregroundStyle(Stark.muted)
                }
            }.padding(.horizontal, 6)
        }
    }
}

struct CamsView: View {
    @ObservedObject var store: StarkStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                PageHeader(title: "SentryCam")
                if store.events.isEmpty {
                    Text("No recent detections, or Frigate is unreachable.").font(.system(size: 11)).foregroundStyle(Stark.muted)
                }
                ForEach(store.events) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.label.capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(Stark.text)
                            Text(e.camera).font(.system(size: 10)).foregroundStyle(Stark.muted)
                        }
                        Spacer()
                        Text(ago(e.time)).font(.system(size: 11, weight: .medium)).foregroundStyle(Stark.rose)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Stark.panel))
                }
                Button("Refresh") { Task { await store.refreshEvents() } }
            }.padding(.horizontal, 6)
        }
    }
}

struct MessagesView: View {
    @ObservedObject var store: StarkStore
    @State private var draft = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                PageHeader(title: "Nocturne")
                if store.relayURL.isEmpty {
                    Text("Add your relay address and token in Settings (last page).").font(.system(size: 11)).foregroundStyle(Stark.muted)
                } else {
                    ForEach(store.messages.suffix(8)) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.sender).font(.system(size: 9, weight: .bold)).foregroundStyle(m.sender == store.myName ? Stark.muted : Stark.rose)
                            Text(m.text).font(.system(size: 12)).foregroundStyle(Stark.text)
                        }
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Stark.panel))
                    }
                    TextField("Reply", text: $draft)
                    Button("Send") { let t = draft; draft = ""; Task { await store.send(t) } }.disabled(draft.isEmpty)
                }
            }.padding(.horizontal, 6)
        }
        .onAppear { store.markRead() }
    }
}

struct JarvisView: View {
    @ObservedObject var store: StarkStore
    @State private var question = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageHeader(title: "J.A.R.V.I.S.")
                TextField("Ask…", text: $question)
                Button(store.busy ? "Thinking…" : "Ask") { let q = question; question = ""; Task { await store.askJarvis(q) } }
                    .disabled(question.isEmpty || store.busy)
                if !store.jarvisReply.isEmpty {
                    Text(store.jarvisReply).font(.system(size: 12)).foregroundStyle(Stark.text)
                }
            }.padding(.horizontal, 6)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: StarkStore
    var body: some View {
        Form {
            Section("NAS") { TextField("NAS address", text: $store.nasHost) }
            Section("Nocturne") {
                TextField("Relay URL (https://…)", text: $store.relayURL)
                TextField("Token", text: $store.relayToken)
                TextField("Room", text: $store.relayRoom)
                TextField("Your name", text: $store.myName)
            }
            Section("Payday") {
                DatePicker("A payday", selection: $store.payAnchor, displayedComponents: .date)
                Picker("Paid", selection: $store.payEveryDays) {
                    Text("Monthly").tag(0); Text("Weekly").tag(7); Text("Fortnightly").tag(14); Text("4-weekly").tag(28)
                }
            }
            Section { Button("Refresh everything") { Task { await store.refreshAll() } } }
        }
    }
}
