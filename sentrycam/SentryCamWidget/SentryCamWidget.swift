import WidgetKit
import SwiftUI

struct SentryEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let event: SharedStore.LastEvent?
}

struct SentryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SentryEntry {
        SentryEntry(date: .now, image: nil, event: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (SentryEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SentryEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
    private func current() -> SentryEntry {
        SentryEntry(date: .now, image: SharedStore.loadSnapshot(), event: SharedStore.loadEvent())
    }
}

struct SentryCamWidgetEntryView: View {
    var entry: SentryEntry

    private var deepLink: URL {
        if let id = entry.event?.id { return URL(string: "sentrycam://event/\(id)") ?? URL(string: "sentrycam://open")! }
        return URL(string: "sentrycam://open")!
    }

    var body: some View {
        ZStack {
            if let image = entry.image {
                Image(uiImage: image).resizable().scaledToFill()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                if let event = entry.event {
                    VStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(event.label.capitalized) · \(pretty(event.camera))").font(.caption2.bold())
                            Text(event.time, style: .relative).font(.system(size: 9)).opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video.fill").font(.title2)
                    Text("SentryCam").font(.caption.bold())
                    Text("Open to view cameras").font(.system(size: 9)).opacity(0.7)
                }
                .foregroundStyle(.white)
            }
        }
        .containerBackground(.black, for: .widget)
        .widgetURL(deepLink)
    }

    private func pretty(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct SentryCamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SentryCamWidget", provider: SentryProvider()) { entry in
            SentryCamWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Latest Camera")
        .description("The latest camera snapshot and event.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SentryCamWidgetBundle: WidgetBundle {
    var body: some Widget { SentryCamWidget() }
}
