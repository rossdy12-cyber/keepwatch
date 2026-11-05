import UIKit

/// One place for the app's haptic taps, so the Settings switch can turn them all off.
enum Haptics {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "lumen.camera.haptics") as? Bool ?? true
    }

    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// How many megapixels a photo is saved at.
enum PhotoResolution: String, CaseIterable, Identifiable, Codable {
    /// The sensor's full resolution (48 MP on the iPhone 16's main camera).
    case max = "Max"
    /// Binned, ~12 MP: smaller files, better in low light.
    case standard = "12 MP"
    var id: String { rawValue }
}
