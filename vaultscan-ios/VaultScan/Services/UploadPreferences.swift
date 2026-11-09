import Foundation

struct UploadPreferences {
    private enum Key {
        static let wifiOnly = "uploads.wifiOnly"
        static let notificationsEnabled = "uploads.notificationsEnabled"
    }

    var wifiOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Key.wifiOnly) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Key.wifiOnly) }
    }

    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.notificationsEnabled) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Key.notificationsEnabled) }
    }
}
