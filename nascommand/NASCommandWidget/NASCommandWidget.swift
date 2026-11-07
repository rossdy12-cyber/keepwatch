import WidgetKit
import SwiftUI

struct NASEntry: TimelineEntry {
    let date: Date
    let snapshot: StatusSnapshot?
}

struct NASProvider: TimelineProvider {
    func placeholder(in context: Context) -> NASEntry { NASEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NASEntry) -> Void) {
        completion(NASEntry(date: .now, snapshot: SnapshotStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NASEntry>) -> Void) {
        let entry = NASEntry(date: .now, snapshot: SnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(20 * 60))))
    }
}

struct NASCommandWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NASEntry

    private let green = Color(red: 0.26, green: 0.78, blue: 0.45)
    private let red = Color(red: 0.93, green: 0.33, blue: 0.33)

    var body: some View {
        Group {
            if let s = entry.snapshot {
                family == .systemSmall ? AnyView(small(s)) : AnyView(medium(s))
            } else {
                placeholder
            }
        }
        .containerBackground(Color(red: 0.06, green: 0.07, blue: 0.09), for: .widget)
    }

    private func small(_ s: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(s.everythingOK ? green : red).frame(width: 10, height: 10)
                Text(s.everythingOK ? "All good" : "Attention").font(.subheadline.bold()).foregroundStyle(.white)
            }
            Spacer()
            Text("\(s.appsRunning)/\(s.appsTotal)").font(.system(.title, design: .rounded).bold()).foregroundStyle(.white)
            Text("apps running").font(.caption2).foregroundStyle(.secondary)
            if !s.poolsHealthy { Text("Pool: \(s.badPools.first ?? "degraded")").font(.caption2).foregroundStyle(red) }
            else if !s.stoppedApps.isEmpty { Text("Stopped: \(s.stoppedApps.first ?? "")").font(.caption2).foregroundStyle(red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ s: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(s.everythingOK ? green : red).frame(width: 10, height: 10)
                Text(s.host).font(.subheadline.bold()).foregroundStyle(.white)
                Spacer()
                Text(s.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            Divider().overlay(.white.opacity(0.1))
            row("Pools", s.poolsHealthy ? "all healthy" : "⚠︎ " + (s.badPools.joined(separator: ", ")), s.poolsHealthy)
            row("Apps", "\(s.appsRunning) of \(s.appsTotal) running", s.stoppedApps.isEmpty)
            if !s.stoppedApps.isEmpty {
                Text("Stopped: " + s.stoppedApps.prefix(4).joined(separator: ", ")).font(.caption2).foregroundStyle(red)
            }
            row("Alerts", s.alerts == 0 ? "none" : "\(s.alerts) active", s.alerts == 0)
        }
    }

    private func row(_ label: String, _ value: String, _ ok: Bool) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.bold()).foregroundStyle(ok ? .white : red)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "server.rack").font(.title2)
            Text("NAS Command").font(.caption.bold())
            Text("Open to connect").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

struct NASCommandWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NASCommandWidget", provider: NASProvider()) { entry in
            NASCommandWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("NAS Status")
        .description("Your TrueNAS health at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct NASCommandWidgetBundle: WidgetBundle {
    var body: some Widget { NASCommandWidget() }
}
