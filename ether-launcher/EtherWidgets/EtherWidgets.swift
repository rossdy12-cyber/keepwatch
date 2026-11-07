import WidgetKit
import SwiftUI

struct EtherWidgetEntry: TimelineEntry {
    let date: Date
    let inStock: Int
    let lowStock: Int
    let outStock: Int
    let dailySales: Int
    let activeVisitors: Int
    let cpu: Int
}

struct EtherWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> EtherWidgetEntry {
        EtherWidgetEntry(
            date: Date(),
            inStock: 28903,
            lowStock: 4491,
            outStock: 9051,
            dailySales: 520,
            activeVisitors: 62,
            cpu: 18
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (EtherWidgetEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EtherWidgetEntry>) -> Void) {
        let fallback = placeholder(in: context)
        if context.isPreview {
            completion(Timeline(entries: [fallback], policy: .after(Date().addingTimeInterval(300))))
            return
        }

        Task {
            var entry = fallback
            for host in ["192.168.0.185:8787", "100.79.246.119:8787"] {
                if let url = URL(string: "http://\(host)/api/state") {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 1.5
                    if let (data, _) = try? await URLSession.shared.data(for: req),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let stock = (json["stock"] as? [String: Any])?["summary"] as? [String: Any]
                        let ecom = (json["ecommerce"] as? [String: Any])?["metrics"] as? [String: Any]
                        let ga = (json["ads"] as? [String: Any])?["gaSummary"] as? [String: Any]
                        let cpuDict = (json["telemetry"] as? [String: Any])?["cpu"] as? [String: Any]
                        entry = EtherWidgetEntry(
                            date: Date(),
                            inStock: stock?["inStockCount"] as? Int ?? 28903,
                            lowStock: stock?["lowStockCount"] as? Int ?? 4491,
                            outStock: stock?["outOfStockCount"] as? Int ?? 9051,
                            dailySales: Int((ecom?["dailyRevenue"] as? NSNumber)?.doubleValue ?? 520),
                            activeVisitors: ga?["activeVisitors"] as? Int ?? 62,
                            cpu: Int((cpuDict?["percent"] as? NSNumber)?.doubleValue ?? 18)
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
    QuickTile(id: "rb", label: "Racebolt", icon: "wrench.and.screwdriver.fill", scheme: "https://raceboltuk.com/wp-admin/edit.php?post_type=product"),
    QuickTile(id: "photos", label: "Photos", icon: "photo.fill", scheme: "photos-redirect://"),
    QuickTile(id: "maps", label: "Maps", icon: "map.fill", scheme: "maps://"),
    QuickTile(id: "yt", label: "YouTube", icon: "play.rectangle.fill", scheme: "youtube://"),
    QuickTile(id: "spotify", label: "Spotify", icon: "music.note", scheme: "spotify://")
]

struct EtherOrbWidgetView: View {
    var entry: EtherWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Æ  T  H  E  R")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                Spacer()
                Text("● \(entry.activeVisitors) LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }

            if family == .systemLarge {
                // Static Glowing Neural Orb Ring in Large Widget
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.cyan.opacity(0.35), Color.blue.opacity(0.1), .clear],
                                center: .center,
                                startRadius: 4,
                                endRadius: 55
                            )
                        )
                        .frame(width: 110, height: 110)
                    Circle()
                        .strokeBorder(Color.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .frame(width: 82, height: 82)
                    VStack(spacing: 2) {
                        Text(entry.date, style: .time)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("ÆTHER OS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
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
                let slice = family == .systemLarge ? Array(widgetTiles.prefix(8)) : Array(widgetTiles.prefix(4))
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
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.32), lineWidth: 0.8))
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

struct EtherGridWidgetView: View {
    var entry: EtherWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        let slice = family == .systemLarge ? widgetTiles : Array(widgetTiles.prefix(4))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ÆTHER APP LAUNCHER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
            }
            LazyVGrid(columns: cols, spacing: 7) {
                ForEach(slice) { tile in
                    if let dest = URL(string: "etherlauncher://launch?scheme=\(tile.scheme)") {
                        Link(destination: dest) {
                            VStack(spacing: 4) {
                                Image(systemName: tile.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.cyan)
                                Text(tile.label)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(9)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.cyan.opacity(0.35), lineWidth: 0.8))
                        }
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.008, green: 0.022, blue: 0.055), Color(red: 0.018, green: 0.06, blue: 0.12)],
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
        EtherLauncherGridWidget()
    }
}

struct EtherLauncherHomeWidget: Widget {
    let kind: String = "EtherLauncherHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EtherWidgetProvider()) { entry in
            EtherOrbWidgetView(entry: entry)
        }
        .configurationDisplayName("ÆTHER Orb & Telemetry")
        .description("Neural Orb, Racebolt Stock/Sales, and Quick App Launcher.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct EtherLauncherGridWidget: Widget {
    let kind: String = "EtherLauncherGridWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EtherWidgetProvider()) { entry in
            EtherGridWidgetView(entry: entry)
        }
        .configurationDisplayName("ÆTHER 12-App Launcher Grid")
        .description("Full Sci-Fi Home Screen App Grid for iPhone.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
