import Foundation
import BackgroundTasks
import WidgetKit
import UserNotifications

/// Builds a StatusSnapshot from the live TrueNAS data and persists it for the widget.
enum NASStatus {
    static func snapshot(info: SystemInfo?, pools: [NASPool], apps: [NASApp], alerts: [NASAlert]) -> StatusSnapshot {
        let badPools = pools.filter { ($0.status ?? "").uppercased() != "ONLINE" || $0.healthy == false }.map { $0.name }
        let running = apps.filter { ($0.state ?? "").uppercased() == "RUNNING" }.count
        let stopped = apps.filter {
            let state = ($0.state ?? "").uppercased()
            return state != "RUNNING" && state != "DEPLOYING"
        }.map { $0.name }
        let active = alerts.filter { !($0.dismissed ?? false) }.count
        return StatusSnapshot(host: info?.hostname ?? "TrueNAS", poolsHealthy: badPools.isEmpty, badPools: badPools,
                              appsRunning: running, appsTotal: apps.count, stoppedApps: stopped, alerts: active, date: Date())
    }

    @MainActor
    static func persist(info: SystemInfo?, pools: [NASPool], apps: [NASApp], alerts: [NASAlert]) {
        SnapshotStore.save(snapshot(info: info, pools: pools, apps: apps, alerts: alerts))
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Periodic background check that posts a local notification when something goes wrong.
enum BackgroundRefresh {
    static let identifier = "app.nascommand.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()   // chain the next check
        let defaults = UserDefaults.standard
        let address = defaults.string(forKey: "nas.address") ?? ""
        let apiKey = Keychain.get("apiKey")
        guard !ServerAddress.normalize(address).isEmpty, !apiKey.isEmpty else { return }
        TrustDelegate.shared.setTrusted(host: ServerAddress.host(of: address), trusted: defaults.bool(forKey: "nas.trustSelfSigned"))

        let client = TrueNASClient(address: address, apiKey: apiKey)
        let previous = SnapshotStore.load()
        let info = try? await client.systemInfo()
        let pools = (try? await client.pools()) ?? []
        let apps = (try? await client.apps()) ?? []
        let alerts = (try? await client.alerts()) ?? []
        // Nothing reachable: don't overwrite a good snapshot or alarm the user.
        guard info != nil || !pools.isEmpty || !apps.isEmpty else { return }

        let now = NASStatus.snapshot(info: info, pools: pools, apps: apps, alerts: alerts)
        SnapshotStore.save(now)
        WidgetCenter.shared.reloadAllTimelines()
        notifyIfWorse(previous: previous, now: now)
    }

    private static func notifyIfWorse(previous: StatusSnapshot?, now: StatusSnapshot) {
        var lines: [String] = []
        let newBadPools = Set(now.badPools).subtracting(previous?.badPools ?? [])
        if !newBadPools.isEmpty { lines.append("Pool problem: " + newBadPools.sorted().joined(separator: ", ")) }
        let newStopped = Set(now.stoppedApps).subtracting(previous?.stoppedApps ?? [])
        if !newStopped.isEmpty { lines.append("App stopped: " + newStopped.sorted().prefix(5).joined(separator: ", ")) }
        guard !lines.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = now.host
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
