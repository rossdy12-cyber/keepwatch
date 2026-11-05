import CoreGraphics
import Foundation

/// Every adjustment for one photo. All values are 0 when untouched.
struct EditRecipe: Equatable {
    // Light
    var exposure: Double = 0      // -3…3 EV
    var contrast: Double = 0      // -1…1
    var highlights: Double = 0    // -1…1 (negative recovers bright areas)
    var shadows: Double = 0       // -1…1 (positive lifts dark areas)
    var whites: Double = 0        // -1…1
    var blacks: Double = 0        // -1…1
    // Colour
    var temperature: Double = 0   // -1 (cool) … 1 (warm)
    var tint: Double = 0          // -1 (green) … 1 (magenta)
    var vibrance: Double = 0      // -1…1
    var saturation: Double = 0    // -1…1
    // Detail and effects
    var clarity: Double = 0       // -1…1
    var sharpness: Double = 0     // 0…1
    var grain: Double = 0         // 0…1
    var vignette: Double = 0      // -1 (lighter edges) … 1 (darker edges)
    var fade: Double = 0          // 0…1
    // AI (done on the iPhone)
    var autoEnhance: Double = 0     // 0…1 strength of Magic Enhance
    var subjectPop: Double = 0      // 0…1
    var backgroundBlur: Double = 0  // 0…1
    var noiseReduction: Double = 0  // 0…1
    // Look
    var look: String = Look.none.id
    var lookAmount: Double = 1    // 0…1
    // Local adjustments (radial / graduated masks)
    var masks: [MaskLayer] = []
    // Crop
    var aspect: CropAspect = .original
    var straighten: Double = 0    // degrees, -15…15

    var isUntouched: Bool { self == EditRecipe() }
}

/// One local adjustment: a radial or graduated (linear) mask with its own sliders. Geometry is in
/// normalised image coordinates (0–1, origin top-left of the upright photo).
struct MaskLayer: Identifiable, Equatable {
    enum Kind: String, Equatable { case radial = "Radial", linear = "Graduated" }

    let id: String
    var kind: Kind
    var invert: Bool = false
    var center = CGPoint(x: 0.5, y: 0.5)   // radial centre, or the start (full-strength end) of a graduated mask
    var radius: Double = 0.35              // radial size, as a fraction of the shorter side
    var end = CGPoint(x: 0.5, y: 0.85)     // graduated: where the effect fades to nothing

    var exposure: Double = 0     // -2…2 EV
    var contrast: Double = 0     // -1…1
    var saturation: Double = 0   // -1…1
    var temperature: Double = 0  // -1…1
    var clarity: Double = 0      // -1…1

    var hasEffect: Bool { exposure != 0 || contrast != 0 || saturation != 0 || temperature != 0 || clarity != 0 }

    static func new(_ kind: Kind) -> MaskLayer { MaskLayer(id: UUID().uuidString, kind: kind) }

    static let adjustments: [(name: String, range: ClosedRange<Double>, keyPath: WritableKeyPath<MaskLayer, Double>)] = [
        ("Exposure", -2...2, \.exposure),
        ("Contrast", -1...1, \.contrast),
        ("Saturation", -1...1, \.saturation),
        ("Temperature", -1...1, \.temperature),
        ("Clarity", -1...1, \.clarity),
    ]
}

enum CropAspect: String, CaseIterable, Identifiable {
    case original = "Original", square = "1:1", portrait = "4:5", classic = "3:2", wide = "16:9", cinema = "2.39:1"
    var id: String { rawValue }

    /// Width ÷ height, or nil to keep the photo's own shape. Follows the photo's orientation.
    func ratio(forLandscape landscape: Bool) -> Double? {
        let value: Double
        switch self {
        case .original: return nil
        case .square: value = 1
        case .portrait: value = 4.0 / 5.0
        case .classic: value = 3.0 / 2.0
        case .wide: value = 16.0 / 9.0
        case .cinema: value = 2.39
        }
        if self == .square || self == .portrait { return value }
        return landscape ? value : 1 / value
    }
}

/// A slider in the editor.
struct Adjustment: Identifiable {
    let id: String
    let name: String
    let range: ClosedRange<Double>
    let keyPath: WritableKeyPath<EditRecipe, Double>

    static let light: [Adjustment] = [
        Adjustment(id: "exposure", name: "Exposure", range: -3...3, keyPath: \.exposure),
        Adjustment(id: "contrast", name: "Contrast", range: -1...1, keyPath: \.contrast),
        Adjustment(id: "highlights", name: "Highlights", range: -1...1, keyPath: \.highlights),
        Adjustment(id: "shadows", name: "Shadows", range: -1...1, keyPath: \.shadows),
        Adjustment(id: "whites", name: "Whites", range: -1...1, keyPath: \.whites),
        Adjustment(id: "blacks", name: "Blacks", range: -1...1, keyPath: \.blacks),
    ]
    static let colour: [Adjustment] = [
        Adjustment(id: "temperature", name: "Temperature", range: -1...1, keyPath: \.temperature),
        Adjustment(id: "tint", name: "Tint", range: -1...1, keyPath: \.tint),
        Adjustment(id: "vibrance", name: "Vibrance", range: -1...1, keyPath: \.vibrance),
        Adjustment(id: "saturation", name: "Saturation", range: -1...1, keyPath: \.saturation),
    ]
    static let ai: [Adjustment] = [
        Adjustment(id: "autoEnhance", name: "Magic Enhance", range: 0...1, keyPath: \.autoEnhance),
        Adjustment(id: "subjectPop", name: "Subject pop", range: 0...1, keyPath: \.subjectPop),
        Adjustment(id: "backgroundBlur", name: "Background blur", range: 0...1, keyPath: \.backgroundBlur),
        Adjustment(id: "noiseReduction", name: "Reduce noise", range: 0...1, keyPath: \.noiseReduction),
    ]
    static let detail: [Adjustment] = [
        Adjustment(id: "clarity", name: "Clarity", range: -1...1, keyPath: \.clarity),
        Adjustment(id: "sharpness", name: "Sharpen", range: 0...1, keyPath: \.sharpness),
        Adjustment(id: "grain", name: "Grain", range: 0...1, keyPath: \.grain),
        Adjustment(id: "vignette", name: "Vignette", range: -1...1, keyPath: \.vignette),
        Adjustment(id: "fade", name: "Fade", range: 0...1, keyPath: \.fade),
    ]
}
