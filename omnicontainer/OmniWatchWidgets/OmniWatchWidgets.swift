import WidgetKit
import SwiftUI

struct JarvisComplicationEntry: TimelineEntry {
    let date: Date
    let status: String
    let nextPaydayDays: Int
}

struct JarvisComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarvisComplicationEntry {
        JarvisComplicationEntry(date: Date(), status: "NOMINAL", nextPaydayDays: 11)
    }

    func getSnapshot(in context: Context, completion: @escaping (JarvisComplicationEntry) -> Void) {
        completion(JarvisComplicationEntry(date: Date(), status: "NOMINAL", nextPaydayDays: 11))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JarvisComplicationEntry>) -> Void) {
        let entry = JarvisComplicationEntry(date: Date(), status: "NOMINAL", nextPaydayDays: 11)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct JarvisComplicationView: View {
    var entry: JarvisComplicationProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.cyan)
                    Text("JARVIS")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.shield.fill").foregroundColor(.cyan)
                    Text("J.A.R.V.I.S. WRIST OS").font(.system(size: 10, weight: .black, design: .monospaced))
                }
                Text("🔓 Tap: PC Unlock & Voice")
                    .font(.system(size: 10, weight: .semibold))
                Text("NAS & Cameras: \(entry.status)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        case .accessoryInline:
            Text("⚡ J.A.R.V.I.S. \(entry.status) • 🔓 PC Ready")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bolt.shield.fill").foregroundColor(.cyan)
            }
        }
    }
}

@main
struct OmniWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JarvisWristWidget()
    }
}

struct JarvisWristWidget: Widget {
    let kind: String = "JarvisWristWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarvisComplicationProvider()) { entry in
            JarvisComplicationView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("J.A.R.V.I.S. Wrist OS")
        .description("Quick launch for Work PC & Bazzite Unlock, SentryCam, and J.A.R.V.I.S. Voice.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}
