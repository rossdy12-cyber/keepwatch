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
        case .night: return "Several longer exposures, lined up and merged, at full resolution. Hold still for a second."
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

/// Who sets the exposure: the camera, you, or a mix.
enum ExposureProgram: String, CaseIterable, Identifiable, Codable {
    case auto = "A", shutter = "S", iso = "ISO", manual = "M"
    var id: String { rawValue }
    var help: String {
        switch self {
        case .auto: return "Auto"
        case .shutter: return "Shutter priority: you pick the shutter, ISO follows the light"
        case .iso: return "ISO priority: you pick the ISO, the shutter follows the light"
        case .manual: return "Manual"
        }
    }
}

/// Video stabilisation.
enum StabilizationChoice: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto", off = "Off", standard = "Standard", cinematic = "Cinematic",
         extended = "Cinematic extended", enhanced = "Extra steady (Action-like)"
    var id: String { rawValue }

    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .auto: return .auto
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .extended: return .cinematicExtended
        case .enhanced:
            if #available(iOS 18.0, *) { return .cinematicExtendedEnhanced }
            return .cinematicExtended
        }
    }
}

/// Cinema frame lines for video.
enum FrameGuide: String, CaseIterable, Identifiable, Codable {
    case none = "None", scope = "2.39:1", flat = "1.85:1", academy = "4:3", square = "1:1"
    var id: String { rawValue }
    /// Long side ÷ short side.
    var ratio: CGFloat? {
        switch self {
        case .none: return nil
        case .scope: return 2.39
        case .flat: return 1.85
        case .academy: return 4.0 / 3.0
        case .square: return 1
        }
    }
}

enum ScopeStyle: String, CaseIterable, Identifiable, Codable {
    case luma = "Brightness", rgb = "RGB", waveform = "Waveform"
    var id: String { rawValue }
}

/// What the live QR / document finder sees (normalised, top-left origin, in live-frame space).
final class DetectionFeed: ObservableObject {
    @Published var code: String?
    @Published var document: [CGPoint]?
    /// The live frame's size, to place the outline over the preview.
    @Published var frameSize: CGSize = .zero
}
