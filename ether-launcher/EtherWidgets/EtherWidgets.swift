import WidgetKit
import SwiftUI

struct EtherWidgetEntry: TimelineEntry {
    let date: Date
    let inStock: Int
    let lowStock: Int
    let dailySales: Int
    let activeVisitors: Int
}

struct EtherWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> EtherWidgetEntry {
        EtherWidgetEntry(date: Date(), inStock: 28903, lowStock: 4491, dailySales: 520, activeVisitors: 62)
    }

    func getSnapshot(in context: Context, completion: @escaping (EtherWidgetEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EtherWidgetEntry>) -> Void) {
        Task {
            var entry = EtherWidgetEntry(date: Date(), inStock: 28903, lowStock: 4491, dailySales: 520, activeVisitors: 62)
            for host in ["192.168.0.185:8787", "100.79.246.119:8787"] {
                if let url = URL(string: "http://\(host)/api/state") {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 2.5
                    if let (data, _) = try? await URLSession.shared.data(for: req),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let stock = (json["stock"] as? [String: Any])?["summary"] as? [String: Any]
                        let ecom = (json["ecommerce"] as? [String: Any])?["metrics"] as? [String: Any]
                        let ga = (json["ads"] as? [String: Any])?["gaSummary"] as? [String: Any]
                        entry = EtherWidgetEntry(
                            date: Date(),
                            inStock: stock?["inStockCount"] as? Int ?? 28903,
                            lowStock: stock?["lowStockCount"] as? Int ?? 4491,
                            dailySales: Int((ecom?["dailyRevenue"] as? NSNumber)?.doubleValue ?? 520),
                            activeVisitors: ga?["activeVisitors"] as? Int ?? 62
                        )
                        break
                    }
                }
            }
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct QuickTile: Identifiable {
    let id: String
    let label: String
    let icon: String
    let scheme: String
}

private let widgetTiles: [QuickTile] = [
    QuickTile(id: "phone", label: "Phone", icon: "phone.fill", scheme: "tel://"),
    QuickTile(id: "msg", label: "Messages", icon: "message.fill", scheme: "sms://"),
    QuickTile(id: "wa", label: "WhatsApp", icon: "bubble.left.and.bubble.right.fill", scheme: "whatsapp://"),
    QuickTile(id: "safari", label: "Safari", icon: "safari.fill", scheme: "x-web-search://"),
    QuickTile(id: "mail", label: "iCloud", icon: "envelope.fill", scheme: "message://"),
    QuickTile(id: "work", label: "Work Mail", icon: "tray.full.fill", scheme: "ms-outlook://"),
    QuickTile(id: "cam", label: "Camera", icon: "camera.fill", scheme: "camera://"),
    QuickTile(id: "rb", label: "Racebolt", icon: "wrench.and.screwdriver.fill", scheme: "https://raceboltuk.com/wp-admin/edit.php?post_type=product")
]

struct EtherWidgetView: View {
    var entry: EtherWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Æ T H E R")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                Spacer()
                Text("● \(entry.activeVisitors) LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }

            HStack(spacing: 6) {
                MiniMetric(val: "\(entry.inStock)", lbl: "IN STOCK")
                MiniMetric(val: "£\(entry.dailySales)", lbl: "24H SALES")
                if family != .systemSmall {
                    MiniMetric(val: "\(entry.lowStock)", lbl: "LOW SKU")
                }
            }

            if family != .systemSmall {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                let slice = family == .systemLarge ? widgetTiles : Array(widgetTiles.prefix(4))
                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(slice) { tile in
                        if let dest = URL(string: "etherlauncher://launch?scheme=\(tile.scheme)") {
                            Link(destination: dest) {
                                VStack(spacing: 3) {
                                    Image(systemName: tile.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.cyan)
                                    Text(tile.label)
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.3), lineWidth: 0.8))
                            }
                        }
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.01, green: 0.03, blue: 0.07), Color(red: 0.02, green: 0.07, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct MiniMetric: View {
    let val: String
    let lbl: String
    var body: some View {
        VStack(spacing: 1) {
            Text(val)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(lbl)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.4))
        .cornerRadius(7)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.cyan.opacity(0.25), lineWidth: 0.7))
    }
}

@main
struct EtherLauncherWidgetBundle: WidgetBundle {
    var body: some Widget {
        EtherLauncherHomeWidget()
    }
}

struct EtherLauncherHomeWidget: Widget {
    let kind: String = "EtherLauncherHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EtherWidgetProvider()) { entry in
            EtherWidgetView(entry: entry)
        }
        .configurationDisplayName("ÆTHER OS Home Launcher")
        .description("Interactive ÆTHER HUD Home Screen Launcher & Racebolt Live Telemetry.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
