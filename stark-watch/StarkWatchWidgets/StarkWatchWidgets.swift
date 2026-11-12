import WidgetKit
import SwiftUI

// Complications for Apple's own watch faces. Each one fetches its own data (the app and the
// extension don't share storage without an App Group), and tapping opens the matching page.

private let nasHost = "100.85.127.42"
private let crimson = Color(red: 0.91, green: 0.25, blue: 0.36)

private func fetchJSON(_ req: URLRequest) async -> Any? {
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

// MARK: - NAS status

struct NASEntry: TimelineEntry {
    let date: Date
    let healthy: Bool?      // nil = couldn't reach the NAS
    let running: Int?
    let total: Int?
}

struct NASProvider: TimelineProvider {
    func placeholder(in context: Context) -> NASEntry { NASEntry(date: Date(), healthy: true, running: 26, total: 26) }
    func getSnapshot(in context: Context, completion: @escaping (NASEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NASEntry>) -> Void) {
        Task {
            let entry = await load()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
    private func load() async -> NASEntry {
        guard let u = URL(string: "http://\(nasHost):9092/api/antigravity/exec") else { return NASEntry(date: Date(), healthy: nil, running: nil, total: nil) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"; req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "zpool status -x 2>&1 | head -n 1; echo '@@'; docker ps -q 2>/dev/null | wc -l; echo '@@'; docker ps -aq 2>/dev/null | wc -l"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        guard let obj = await fetchJSON(req) as? [String: Any] else { return NASEntry(date: Date(), healthy: nil, running: nil, total: nil) }
        let out = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? ""
        let parts = out.components(separatedBy: "@@").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return NASEntry(date: Date(),
                        healthy: (parts.first ?? "").contains("all pools are healthy"),
                        running: parts.count > 1 ? Int(parts[1]) : nil,
                        total: parts.count > 2 ? Int(parts[2]) : nil)
    }
}

struct NASView: View {
    let entry: NASEntry
    @Environment(\.widgetFamily) private var family

    private var word: String { entry.healthy == nil ? "No link" : (entry.healthy == true ? "Healthy" : "Alert") }
    private var icon: String { entry.healthy == true ? "checkmark.shield.fill" : (entry.healthy == nil ? "wifi.slash" : "exclamationmark.triangle.fill") }
    private var apps: String {
        if let r = entry.running, let t = entry.total { return "\(r)/\(t) apps" }
        return "apps —"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("NAS", systemImage: "externaldrive.fill").font(.headline).foregroundStyle(crimson).widgetAccentable()
                    Text("Pools: \(word)").font(.body)
                    Text(apps).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                Label("NAS \(word) · \(apps)", systemImage: icon)
            case .accessoryCorner:
                Image(systemName: icon).font(.title3).widgetAccentable()
                    .widgetLabel { Text("NAS \(word)") }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: icon).font(.system(size: 15, weight: .bold)).widgetAccentable()
                        Text(entry.running.map { "\($0)" } ?? "NAS").font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                }
            }
        }
        .widgetURL(URL(string: "starkface://nas"))
    }
}

struct NASWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StarkNAS", provider: NASProvider()) { entry in
            NASView(entry: entry).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("NAS status")
        .description("Pool health and running apps on your TrueNAS.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

// MARK: - SentryCam last detection

struct CamEntry: TimelineEntry {
    let date: Date
    let label: String?
    let camera: String?
    let time: Date?
}

struct CamProvider: TimelineProvider {
    func placeholder(in context: Context) -> CamEntry { CamEntry(date: Date(), label: "person", camera: "front_door", time: Date().addingTimeInterval(-300)) }
    func getSnapshot(in context: Context, completion: @escaping (CamEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CamEntry>) -> Void) {
        Task {
            let entry = await load()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(10 * 60))))
        }
    }
    private func load() async -> CamEntry {
        guard let u = URL(string: "http://\(nasHost):5000/api/events?limit=1&include_thumbnails=0") else { return CamEntry(date: Date(), label: nil, camera: nil, time: nil) }
        var req = URLRequest(url: u); req.timeoutInterval = 10
        guard let arr = await fetchJSON(req) as? [[String: Any]], let e = arr.first else { return CamEntry(date: Date(), label: nil, camera: nil, time: nil) }
        return CamEntry(date: Date(),
                        label: e["label"] as? String,
                        camera: e["camera"] as? String,
                        time: (e["start_time"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
}

struct CamView: View {
    let entry: CamEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("SentryCam", systemImage: "video.fill").font(.headline).foregroundStyle(crimson).widgetAccentable()
                    if let l = entry.label, let t = entry.time {
                        Text(l.capitalized).font(.body)
                        HStack(spacing: 3) {
                            Text(entry.camera ?? "")
                            Text(t, style: .relative)
                        }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No detections").font(.body)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                if let l = entry.label, let t = entry.time {
                    Label { Text("\(l.capitalized) ") + Text(t, style: .relative) } icon: { Image(systemName: "video.fill") }
                } else {
                    Label("No detections", systemImage: "video.fill")
                }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "video.fill").font(.system(size: 13, weight: .bold)).widgetAccentable()
                        if let t = entry.time {
                            Text(t, style: .timer).font(.system(size: 10, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                        } else {
                            Text("—").font(.system(size: 11, weight: .bold))
                        }
                    }
                }
            }
        }
        .widgetURL(URL(string: "starkface://cams"))
    }
}

struct CamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StarkCam", provider: CamProvider()) { entry in
            CamView(entry: entry).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Last detection")
        .description("The most recent Frigate detection.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Launchers (no data: open a page of the Stark Face app)

struct LauncherEntry: TimelineEntry { let date: Date }

struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) { completion(LauncherEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: Date())], policy: .never))
    }
}

struct LauncherView: View {
    let icon: String
    let title: String
    let page: String
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(title, systemImage: icon)
            case .accessoryCorner:
                Image(systemName: icon).font(.title3).widgetAccentable().widgetLabel { Text(title) }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(crimson).widgetAccentable()
                }
            }
        }
        .widgetURL(URL(string: "starkface://\(page)"))
    }
}

struct JarvisWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StarkJarvis", provider: LauncherProvider()) { _ in
            LauncherView(icon: "waveform", title: "Jarvis", page: "jarvis").containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Ask Jarvis")
        .description("Opens J.A.R.V.I.S. on your wrist.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct MessagesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StarkMessages", provider: LauncherProvider()) { _ in
            LauncherView(icon: "bubble.left.fill", title: "Nocturne", page: "messages").containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Nocturne")
        .description("Opens your messages with Lauren.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct FaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StarkFace", provider: LauncherProvider()) { _ in
            LauncherView(icon: "shield.lefthalf.filled", title: "Stark Face", page: "face").containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Stark Face")
        .description("Opens the full Stark face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct StarkWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NASWidget()
        CamWidget()
        JarvisWidget()
        MessagesWidget()
        FaceWidget()
    }
}
