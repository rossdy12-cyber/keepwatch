import Foundation

/// A compact status the app writes for the widget (and compares against for alerts). Shared app↔widget via an
/// App Group; reads degrade gracefully to nil if the group isn't provisioned.
struct StatusSnapshot: Codable, Equatable {
    var host: String
    var poolsHealthy: Bool
    var badPools: [String]
    var appsRunning: Int
    var appsTotal: Int
    var stoppedApps: [String]
    var alerts: Int
    var date: Date

    var everythingOK: Bool { poolsHealthy && stoppedApps.isEmpty && alerts == 0 }
}

enum SnapshotStore {
    static let appGroup = "group.app.nascommand"
    private static let key = "statusSnapshot"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func save(_ snapshot: StatusSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }

    static func load() -> StatusSnapshot? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(StatusSnapshot.self, from: $0) }
    }
}
