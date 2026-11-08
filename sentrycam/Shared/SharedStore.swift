import Foundation
import UIKit

/// Shared between the app and its widget via an App Group. Reads/writes defensively — if the group isn't
/// available (e.g. the sideloader didn't provision it), it degrades to a placeholder widget rather than crashing.
enum SharedStore {
    static let appGroup = "group.app.sentrycam"
    private static let eventKey = "lastEvent"
    private static let snapshotFile = "latest_snapshot.jpg"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func container() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    struct LastEvent: Codable {
        var id: String
        var label: String
        var camera: String
        var time: Date
    }

    static func save(event: LastEvent?, snapshot: Data?) {
        if let event, let data = try? JSONEncoder().encode(event) {
            defaults.set(data, forKey: eventKey)
        }
        if let snapshot, let dir = container() {
            try? snapshot.write(to: dir.appendingPathComponent(snapshotFile), options: .atomic)
        }
    }

    static func loadEvent() -> LastEvent? {
        guard let data = defaults.data(forKey: eventKey) else { return nil }
        return try? JSONDecoder().decode(LastEvent.self, from: data)
    }

    static func loadSnapshot() -> UIImage? {
        guard let dir = container() else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(snapshotFile).path)
    }
}
