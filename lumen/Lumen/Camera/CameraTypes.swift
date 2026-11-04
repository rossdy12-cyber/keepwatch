import AVFoundation
import CoreLocation
import Foundation

/// How the shutter takes a photo.
enum DriveMode: String, CaseIterable, Identifiable, Codable {
    case single = "Single"
    case burst = "Burst"
    case night = "Night"
    case longExposure = "Long exposure"
    case hdr = "HDR"
    case portrait = "Portrait"
    case interval = "Interval"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .single: return "circle"
        case .burst: return "square.stack.3d.down.right"
        case .night: return "moon.stars"
        case .longExposure: return "timer"
        case .hdr: return "circle.lefthalf.filled"
        case .portrait: return "person.crop.circle"
        case .interval: return "clock.arrow.circlepath"
        }
    }

    var help: String {
        switch self {
        case .single: return "One photo per press."
        case .burst: return "Hold the shutter for continuous shots."
        case .night: return "Combines 8 shots for a cleaner low-light photo. Hold still."
        case .longExposure: return "Blends 16 shots: silky water, or light trails. Best on a tripod."
        case .hdr: return "Dark, normal and bright shots merged for bright skies and dark shadows."
        case .portrait: return "Records depth, so the background blur can be adjusted in the editor."
        case .interval: return "Takes a photo every few seconds until you stop it."
        }
    }
}

enum LongExposureStyle: String, CaseIterable, Identifiable, Codable {
    case silky = "Silky water"
    case trails = "Light trails"
    var id: String { rawValue }
}

enum GridStyle: String, CaseIterable, Identifiable, Codable {
    case off = "Off", thirds = "Thirds", golden = "Golden ratio", square = "Square", crosshair = "Centre cross"
    var id: String { rawValue }
}

/// The shape of the saved photo.
enum CaptureAspect: String, CaseIterable, Identifiable, Codable {
    case fourThree = "4:3", sixteenNine = "16:9", square = "1:1"
    var id: String { rawValue }
    /// Long side ÷ short side.
    var ratio: CGFloat {
        switch self {
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .square: return 1
        }
    }
}

enum SlowMoRate: Int, CaseIterable, Identifiable, Codable {
    case fps120 = 120, fps240 = 240
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

/// A microphone the iPhone can record from.
struct MicOption: Identifiable, Hashable {
    let id: String
    let name: String
    let portUID: String
    let dataSourceID: NSNumber?
}

/// Everything a C1/C2/C3 button remembers.
struct CameraPreset: Codable, Equatable {
    var mode: String
    var drive: String
    var format: String
    var videoQuality: String
    var lensLabel: String
    var effectiveZoom: Double
    var autoExposure: Bool
    var iso: Float
    var shutter: Double
    var exposureBias: Float
    var autoWhiteBalance: Bool
    var temperature: Float
    var tint: Float
    var autoFocus: Bool
    var lensPosition: Float
    var look: String
    var aspect: String

    static func key(_ slot: Int) -> String { "lumen.preset.\(slot)" }

    static func load(_ slot: Int) -> CameraPreset? {
        UserDefaults.standard.data(forKey: key(slot)).flatMap { try? JSONDecoder().decode(CameraPreset.self, from: $0) }
    }

    func save(_ slot: Int) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(slot)) }
    }
}

/// Where the phone is, for tagging photos (only while the setting is on).
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private var wanted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
        latest = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wanted, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latest = locations.last
    }
}
