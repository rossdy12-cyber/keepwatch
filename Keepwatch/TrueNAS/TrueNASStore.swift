import Foundation

struct SystemSummary {
    var hostname: String
    var version: String
    var cpuModel: String
    var cores: Int?
    var memoryTotal: Double?
    var uptime: Double?
    var loadAverage: [Double]
}

struct PoolSummary: Identifiable {
    var id: String { name }
    var name: String
    var status: String
    var healthy: Bool
    var size: Double
    var allocated: Double
    var free: Double
    var scan: String?
    var diskCount: Int
    var errorCount: Int

    var usedFraction: Double { size > 0 ? allocated / size : 0 }
}

struct DiskSummary: Identifiable {
    var id: String { name }
    var name: String
    var model: String
    var serial: String
    var size: Double
    var type: String
    var pool: String?
    var temperature: Double?
    var smartResult: String?
}

struct AlertItem: Identifiable {
    var id: String
    var level: String
    var message: String
    var date: Date?

    var isSerious: Bool { ["CRITICAL", "ERROR", "ALERT", "EMERGENCY"].contains(level.uppercased()) }
}

struct AppItem: Identifiable {
    var id: String { name }
    var name: String
    var state: String
    var version: String
    var iconURL: URL?
    var ports: [Int]
    var upgradeAvailable: Bool

    var isRunning: Bool { ["RUNNING", "ACTIVE"].contains(state.uppercased()) }
}

struct LiveStats {
    var cpuUsage: Double?
    var cpuTemperature: Double?
    var memoryServices: Double?
    var memoryCache: Double?
    var memoryFree: Double?
    var receiveRate: Double?
    var sendRate: Double?
}

struct Sample: Identifiable {
    var id: Date { time }
    var time: Date
    var value: Double
}

enum LoadState: Equatable {
    case idle, loading, loaded, failed(String)
}

/// Everything the Overview tab shows about the NAS, plus the connection the Files tab reuses.
@MainActor
final class TrueNASStore: ObservableObject {
    @Published var state: LoadState = .idle
    @Published var system: SystemSummary?
    @Published var live = LiveStats()
    @Published var cpuHistory: [Sample] = []
    @Published var networkHistory: [Sample] = []
    @Published var pools: [PoolSummary] = []
    @Published var disks: [DiskSummary] = []
    @Published var alerts: [AlertItem] = []
    @Published var apps: [AppItem] = []
    @Published var connectionNote: String?
    @Published var notes: [String] = []

    private var client: TrueNASClient?
    private var clientConfig: ServiceConfig?

    /// Returns a connected client for `config`, reusing the open one when nothing changed.
    func connectedClient(_ config: ServiceConfig) async throws -> TrueNASClient {
        if let client, clientConfig == config, client.mode != nil {
            return client
        }
        client?.close()
        let fresh = try TrueNASClient(config: config)
        fresh.onRealtime = { [weak self] fields in self?.applyRealtime(fields) }
        client = fresh
        clientConfig = config
        try await fresh.connect()
        return fresh
    }

    func refresh(_ config: ServiceConfig) async {
        if state != .loaded { state = .loading }
        do {
            let client = try await connectedClient(config)
            await client.subscribeRealtime()
            connectionNote = [client.serverVersion, client.mode?.rawValue].compactMap { $0 }.joined(separator: " · ")
            var problems: [String] = []

            async let infoResult = attempt { try await client.call("system.info") }
            async let poolResult = attempt { try await client.call("pool.query") }
            async let diskResult = attempt { try await client.call("disk.query") }
            async let tempResult = attempt { try await client.call("disk.temperatures", [[String]()]) }
            async let smartResult = attempt { try await client.call("smart.test.results") }
            async let alertResult = attempt { try await client.call("alert.list") }
            async let appResult = attempt { try await client.call("app.query") }

            let info = await infoResult
            let poolValue = await poolResult
            let diskValue = await diskResult
            let temps = (try? (await tempResult).get()) ?? .null
            let smart = (try? (await smartResult).get()) ?? .null
            let alertValue = await alertResult
            let appValue = await appResult

            switch info {
            case .success(let value):
                system = Self.parseSystem(value, version: client.serverVersion)
                // The REST API has no live stats, so estimate CPU from the load average.
                if client.mode == .rest, let load = value["loadavg"][0].double, let cores = value["cores"].double, cores > 0 {
                    live.cpuUsage = min(100, load / cores * 100)
                }
            case .failure(let error):
                problems.append("System info: \(describe(error))")
            }
            switch poolValue {
            case .success(let value): pools = value.array.map(Self.parsePool)
            case .failure(let error): problems.append("Pools: \(describe(error))")
            }
            if let value = try? diskValue.get() {
                disks = Self.parseDisks(value, temps: temps, smart: smart)
            }
            if let value = try? alertValue.get() {
                alerts = Self.parseAlerts(value)
            }
            if let value = try? appValue.get() {
                apps = Self.parseApps(value, base: client.base)
            } else if let value = try? await client.call("chart.release.query") {
                // TrueNAS 24.04 and older call apps "chart releases".
                apps = Self.parseApps(value, base: client.base)
            }
            notes = problems
            state = .loaded
        } catch {
            if isCancellation(error) { return }
            client?.close()
            client = nil
            state = .failed(describe(error))
        }
    }

    private func attempt(_ body: @escaping () async throws -> JSONValue) async -> Result<JSONValue, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    // MARK: - Parsing

    private static func parseSystem(_ value: JSONValue, version: String?) -> SystemSummary {
        SystemSummary(
            hostname: value["hostname"].string ?? "TrueNAS",
            version: version ?? value["version"].string ?? "",
            cpuModel: value["model"].string ?? "",
            cores: value["cores"].int,
            memoryTotal: value["physmem"].double,
            uptime: value["uptime_seconds"].double,
            loadAverage: value["loadavg"].array.compactMap(\.double)
        )
    }

    private static func parsePool(_ value: JSONValue) -> PoolSummary {
        var diskCount = 0
        var errors = 0
        for (_, group) in value["topology"].object {
            for vdev in group.array {
                let children = vdev["children"].array
                let leaves = children.isEmpty ? [vdev] : children
                diskCount += leaves.count
                for leaf in leaves {
                    let stats = leaf["stats"]
                    errors += (stats["read_errors"].int ?? 0) + (stats["write_errors"].int ?? 0) + (stats["checksum_errors"].int ?? 0)
                }
            }
        }
        let scanInfo = value["scan"]
        var scan: String?
        if let function = scanInfo["function"].string {
            let what = function.capitalized
            if scanInfo["state"].string == "SCANNING", let percent = scanInfo["percentage"].double {
                scan = "\(what) running · \(Int(percent))%"
            } else if let end = scanInfo["end_time"].date {
                let errorsFound = scanInfo["errors"].int ?? 0
                scan = "Last \(what.lowercased()) \(Format.relative(end)) · \(errorsFound) errors"
            }
        }
        return PoolSummary(
            name: value["name"].string ?? "pool",
            status: value["status"].string ?? "UNKNOWN",
            healthy: value["healthy"].bool ?? false,
            size: value["size"].double ?? 0,
            allocated: value["allocated"].double ?? 0,
            free: value["free"].double ?? 0,
            scan: scan,
            diskCount: diskCount,
            errorCount: errors
        )
    }

    private static func parseDisks(_ value: JSONValue, temps: JSONValue, smart: JSONValue) -> [DiskSummary] {
        var smartByDisk: [String: String] = [:]
        for entry in smart.array {
            guard let disk = entry["disk"].string else { continue }
            if let latest = entry["tests"].array.first {
                let description = latest["description"].string ?? "Test"
                let status = latest["status_verbose"].string ?? latest["status"].string ?? "unknown"
                smartByDisk[disk] = "\(description): \(status)"
            }
        }
        return value.array.map { disk in
            let name = disk["name"].string ?? disk["devname"].string ?? "disk"
            return DiskSummary(
                name: name,
                model: disk["model"].string ?? "",
                serial: disk["serial"].string ?? "",
                size: disk["size"].double ?? 0,
                type: disk["type"].string ?? "",
                pool: disk["pool"].string,
                temperature: temps[name].double ?? temps[name]["temperature"].double,
                smartResult: smartByDisk[name]
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func parseAlerts(_ value: JSONValue) -> [AlertItem] {
        value.array
            .filter { $0["dismissed"].bool != true }
            .map { alert in
                AlertItem(
                    id: alert["uuid"].string ?? alert["id"].string ?? UUID().uuidString,
                    level: alert["level"].string ?? "INFO",
                    message: Format.stripTags(alert["formatted"].string ?? alert["text"].string ?? ""),
                    date: alert["datetime"].date
                )
            }
            .sorted { ($0.isSerious ? 0 : 1, -($0.date?.timeIntervalSince1970 ?? 0)) < ($1.isSerious ? 0 : 1, -($1.date?.timeIntervalSince1970 ?? 0)) }
    }

    private static func parseApps(_ value: JSONValue, base: String) -> [AppItem] {
        value.array.map { app in
            var ports = Set<Int>()
            for used in app["active_workloads"]["used_ports"].array {
                for host in used["host_ports"].array {
                    if let port = host["host_port"].int { ports.insert(port) }
                }
            }
            let icon = app["metadata"]["icon"].string ?? app["chart_metadata"]["icon"].string
            return AppItem(
                name: app["name"].string ?? app["id"].string ?? "app",
                state: app["state"].string ?? app["status"].string ?? "UNKNOWN",
                version: app["version"].string ?? app["human_version"].string ?? "",
                iconURL: icon.flatMap(URL.init(string:)),
                ports: ports.sorted(),
                upgradeAvailable: app["upgrade_available"].bool ?? false
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Live stats

    private func applyRealtime(_ fields: JSONValue) {
        let cpu = fields["cpu"]
        var usage = cpu["cpu"]["usage"].double ?? cpu["average"]["usage"].double ?? cpu["usage"].double
        if usage == nil {
            let perCore = cpu.object.values.compactMap { $0["usage"].double }
            if !perCore.isEmpty { usage = perCore.reduce(0, +) / Double(perCore.count) }
        }
        var temps = cpu.object.values.compactMap { $0["temp"].double }
        temps += cpu["temperature_celsius"].object.values.compactMap(\.double)
        let temperature = cpu["cpu"]["temp"].double ?? cpu["temp"].double ?? temps.max()

        let memory = fields["memory"]
        let total = memory["physical_memory_total"].double ?? system?.memoryTotal
        let arc = memory["arc_size"].double ?? fields["zfs"]["arc_size"].double ?? memory["classes"]["arc"].double ?? 0
        let available = memory["physical_memory_available"].double ?? memory["classes"]["unused"].double
        if let total, let available {
            live.memoryFree = available
            live.memoryCache = arc
            live.memoryServices = max(0, total - available - arc)
        }

        var received = 0.0
        var sent = 0.0
        var sawInterface = false
        let skipped = ["lo", "veth", "docker", "br-", "kube", "cni", "flannel", "vnet", "tailscale", "virbr"]
        for (name, interface) in fields["interfaces"].object where !skipped.contains(where: { name.hasPrefix($0) }) {
            if let rx = interface["received_bytes_rate"].double ?? interface["received_bytes"].double { received += rx; sawInterface = true }
            if let tx = interface["sent_bytes_rate"].double ?? interface["sent_bytes"].double { sent += tx }
        }

        if let usage { live.cpuUsage = usage }
        if let temperature, temperature > 0 { live.cpuTemperature = temperature }
        if sawInterface {
            live.receiveRate = received
            live.sendRate = sent
        }

        let now = Date()
        if let usage {
            cpuHistory.append(Sample(time: now, value: usage))
            if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
        }
        if sawInterface {
            networkHistory.append(Sample(time: now, value: received + sent))
            if networkHistory.count > 60 { networkHistory.removeFirst(networkHistory.count - 60) }
        }
    }
}
