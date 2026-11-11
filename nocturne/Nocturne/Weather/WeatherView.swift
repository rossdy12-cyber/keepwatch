import SwiftUI
import CoreLocation

@MainActor
final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var place = "…"
    @Published var current: Current?
    @Published var days: [Day] = []
    @Published var error: String?

    struct Current { let temp: Double; let code: Int; let wind: Double; let humidity: Int }
    struct Day: Identifiable { let id = UUID(); let date: Date; let min: Double; let max: Double; let code: Int }

    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        switch mgr.authorizationStatus {
        case .notDetermined: mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: mgr.requestLocation()
        default: error = "Location denied — enable it in Settings to see your skies."
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in if m.authorizationStatus == .authorizedWhenInUse { m.requestLocation() } }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in await self.load(loc) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        Task { @MainActor in self.error = "Couldn't read location." }
    }

    private func load(_ loc: CLLocation) async {
        CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
            Task { @MainActor in self.place = marks?.first?.locality ?? marks?.first?.name ?? "Here" }
        }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m&daily=temperature_2m_max,temperature_2m_min,weather_code&timezone=auto&forecast_days=6")!
        do {
            let (data, _) = try await netSession.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let c = obj["current"] as? [String: Any] {
                current = Current(temp: (c["temperature_2m"] as? Double) ?? 0,
                                  code: (c["weather_code"] as? Int) ?? 0,
                                  wind: (c["wind_speed_10m"] as? Double) ?? 0,
                                  humidity: (c["relative_humidity_2m"] as? Int) ?? 0)
            }
            if let d = obj["daily"] as? [String: Any],
               let times = d["time"] as? [String],
               let mx = d["temperature_2m_max"] as? [Double],
               let mn = d["temperature_2m_min"] as? [Double],
               let cd = d["weather_code"] as? [Int] {
                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
                days = zip(times.indices, times).compactMap { i, t in
                    guard i < mx.count, let date = fmt.date(from: t) else { return nil }
                    return Day(date: date, min: mn[i], max: mx[i], code: cd[i])
                }
            }
            error = nil
        } catch {
            self.error = "Couldn't reach the weather service."
        }
    }
}

enum WX {
    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "moon.stars.fill"
        case 1, 2: return "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly clouded"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Storm"
        default: return "Grey"
        }
    }
}

struct WeatherView: View {
    @EnvironmentObject var store: Store
    @StateObject private var wx = WeatherModel()
    private var theme: GothicTheme { store.theme }

    var body: some View {
        VStack(spacing: 18) {
            GothicTitle(text: "Skies", theme: theme, size: 26).padding(.top, 50)
            if let e = wx.error {
                Spacer()
                Text(e).font(.system(.body, design: .serif)).foregroundStyle(theme.mutedColor)
                    .multilineTextAlignment(.center).padding(40)
                Button("Try again") { wx.start() }.foregroundStyle(theme.accentColor)
                Spacer()
            } else if let c = wx.current {
                Text(wx.place).font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(theme.mutedColor)
                Image(systemName: WX.symbol(c.code))
                    .font(.system(size: 72)).foregroundStyle(theme.accentColor)
                    .shadow(color: theme.accentColor.opacity(0.5), radius: 16)
                Text("\(Int(c.temp.rounded()))°")
                    .font(.system(size: 72, weight: .thin, design: .serif)).foregroundStyle(theme.textColor)
                Text(WX.describe(c.code)).font(.system(.title3, design: .serif)).foregroundStyle(theme.textColor)
                HStack(spacing: 24) {
                    Label("\(Int(c.wind.rounded())) km/h", systemImage: "wind")
                    Label("\(c.humidity)%", systemImage: "humidity")
                }
                .font(.subheadline).foregroundStyle(theme.mutedColor)
                Filigree(theme: theme).padding(.horizontal, 30)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(wx.days) { d in
                            VStack(spacing: 6) {
                                Text(d.date, format: .dateTime.weekday(.abbreviated))
                                    .font(.caption).foregroundStyle(theme.mutedColor)
                                Image(systemName: WX.symbol(d.code)).foregroundStyle(theme.accentColor)
                                Text("\(Int(d.max.rounded()))°").font(.subheadline).foregroundStyle(theme.textColor)
                                Text("\(Int(d.min.rounded()))°").font(.caption).foregroundStyle(theme.mutedColor)
                            }
                            .frame(width: 60).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.panelColor.opacity(0.6)))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                Spacer()
            } else {
                Spacer()
                ProgressView().tint(theme.accentColor)
                Text("Reading the skies…").font(.system(.body, design: .serif)).foregroundStyle(theme.mutedColor).padding(.top, 8)
                Spacer()
            }
        }
        .onAppear { wx.start() }
    }
}
