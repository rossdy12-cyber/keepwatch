import WidgetKit
import SwiftUI

struct ThemeEntry: TimelineEntry {
    let date: Date
    let spec: ThemeSpec
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ThemeEntry {
        ThemeEntry(date: Date(), spec: ThemePresets.all[0])
    }
    func getSnapshot(in context: Context, completion: @escaping (ThemeEntry) -> Void) {
        completion(ThemeEntry(date: Date(), spec: ThemeStorage.loadSelected()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ThemeEntry>) -> Void) {
        let spec = ThemeStorage.loadSelected()
        // Refresh on the minute so the clock stays roughly current; the theme itself
        // updates immediately via WidgetCenter when the app changes it.
        var entries: [ThemeEntry] = []
        let now = Date()
        for m in 0..<15 {
            if let d = Calendar.current.date(byAdding: .minute, value: m, to: now) {
                entries.append(ThemeEntry(date: d, spec: spec))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct PrismWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var body: some View {
        ZStack {
            ThemeBackground(spec: entry.spec)
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(entry.date, format: .dateTime.weekday(.wide))
                        .font(.system(size: 14, weight: .medium, design: .rounded)).opacity(0.85)
                    Text(entry.date, format: .dateTime.day().month(.wide))
                        .font(.system(size: 12, weight: .regular, design: .rounded)).opacity(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(14)
            default:
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.date, format: .dateTime.hour().minute())
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                        Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 16, weight: .medium, design: .rounded)).opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(entry.spec.accentColor)
                }
                .padding(20)
            }
        }
        .foregroundStyle(entry.spec.textColor)
        .containerBackground(for: .widget) { ThemeBackground(spec: entry.spec) }
    }
}

struct PrismWidget: Widget {
    let kind = "PrismWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            PrismWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Prism Clock")
        .description("A clock that matches your active Prism theme.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PrismWidgetBundle: WidgetBundle {
    var body: some Widget { PrismWidget() }
}
