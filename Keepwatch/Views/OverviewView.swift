import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var store: TrueNASStore
    @EnvironmentObject private var router: AppRouter

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await store.refresh(settings[.truenas]) }
            .navigationTitle(store.system?.hostname ?? "Overview")
            .keepwatchChrome()
        }
        .task(id: settings[.truenas]) {
            // Pools, disks, alerts and apps refresh every 30 s; CPU, RAM and network stream live.
            while !Task.isCancelled {
                if settings[.truenas].isConfigured {
                    await store.refresh(settings[.truenas])
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !settings[.truenas].isConfigured {
            MessageCard(symbol: "server.rack", title: "Connect your TrueNAS",
                        message: "Add your TrueNAS address and an API key in Settings to see the health of your server.",
                        color: Theme.accent, actionTitle: "Open Settings") { router.tab = .settings }
        } else if case .failed(let message) = store.state, store.system == nil {
            MessageCard(symbol: "exclamationmark.triangle", title: "Couldn't load TrueNAS", message: message,
                        color: Theme.warning, actionTitle: "Try again") {
                Task { await store.refresh(settings[.truenas]) }
            }
        } else if store.system == nil {
            ProgressView("Connecting to TrueNAS…")
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            header
            if case .failed(let message) = store.state {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
            tiles
            activityChart
            alertsCard
            poolsCard
            disksCard
            appsCard
            ForEach(store.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: store.alerts.contains(where: \.isSerious) ? Theme.danger : Theme.good)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.system?.version ?? "")
                    .font(.subheadline.weight(.semibold))
                Text("Up \(Format.duration(store.system?.uptime)) · \(store.connectionNote ?? "")")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var tiles: some View {
        let live = store.live
        let memoryTotal = store.system?.memoryTotal
        let memoryUsed = live.memoryServices
        var memoryFraction: Double?
        if let memoryUsed, let memoryTotal, memoryTotal > 0 {
            memoryFraction = memoryUsed / memoryTotal
        }
        var cpuCaption: [String] = []
        if let cores = store.system?.cores { cpuCaption.append("\(cores) threads") }
        if live.cpuTemperature != nil { cpuCaption.append(Format.temperature(live.cpuTemperature)) }
        let load = store.system?.loadAverage.prefix(3).map { String(format: "%.2f", $0) } ?? []
        let loadText = load.isEmpty ? "—" : load.joined(separator: " ")
        let cpuFraction: Double? = live.cpuUsage.map { $0 / 100 }

        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(title: "CPU", value: Format.percent(live.cpuUsage),
                     caption: cpuCaption.joined(separator: " · "),
                     symbol: "cpu", color: Theme.level(cpuFraction ?? 0),
                     fraction: cpuFraction)
            StatTile(title: "Memory", value: Format.bytes(memoryUsed),
                     caption: "of \(Format.bytes(memoryTotal)) · ZFS cache \(Format.bytes(live.memoryCache))",
                     symbol: "memorychip", color: Theme.level(memoryFraction ?? 0), fraction: memoryFraction)
            StatTile(title: "Network", value: "↓ " + Format.bitRate(live.receiveRate),
                     caption: "↑ " + Format.bitRate(live.sendRate),
                     symbol: "network", color: Theme.download)
            StatTile(title: "CPU temp", value: Format.temperature(live.cpuTemperature),
                     caption: "Load \(loadText)",
                     symbol: "thermometer.medium", color: Theme.temperatureColor(live.cpuTemperature))
        }
    }

    @ViewBuilder
    private var activityChart: some View {
        if store.cpuHistory.count > 2 {
            Card(title: "Live activity", symbol: "waveform.path.ecg", trailing: "last minute") {
                Chart(store.cpuHistory) { sample in
                    AreaMark(x: .value("Time", sample.time), y: .value("CPU", sample.value))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.time), y: .value("CPU", sample.value))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text("\(Int(number))%") }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
    }

    private var alertsCard: some View {
        Card(title: "Alerts", symbol: "bell.badge", trailing: store.alerts.isEmpty ? nil : "\(store.alerts.count) active") {
            if store.alerts.isEmpty {
                Label("No active alerts", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.good)
                    .font(.subheadline)
            } else {
                ForEach(store.alerts.prefix(8)) { alert in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: alert.isSerious ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(alert.isSerious ? Theme.danger : Theme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.message)
                                .font(.subheadline)
                                .lineLimit(4)
                            Text("\(alert.level.capitalized) · \(Format.relative(alert.date))")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var poolsCard: some View {
        Card(title: "Storage pools", symbol: "externaldrive.connected.to.line.below") {
            if store.pools.isEmpty {
                Text("No pools found.").foregroundStyle(Theme.secondaryText)
            }
            ForEach(store.pools) { pool in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pool.name).font(.subheadline.weight(.semibold))
                        Pill(text: pool.status, color: pool.healthy && pool.status == "ONLINE" ? Theme.good : Theme.danger)
                        Spacer()
                        Text(Format.percent(pool.usedFraction * 100))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    MeterBar(fraction: pool.usedFraction, color: Theme.level(pool.usedFraction))
                    Text("\(Format.bytes(pool.allocated)) used · \(Format.bytes(pool.free)) free of \(Format.bytes(pool.size)) · \(pool.diskCount) disks")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    if pool.errorCount > 0 {
                        Label("\(pool.errorCount) read/write/checksum errors", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                    if let scan = pool.scan {
                        Text(scan)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var disksCard: some View {
        Card(title: "Disks", symbol: "internaldrive", trailing: "\(store.disks.count)") {
            ForEach(store.disks) { disk in
                HStack(spacing: 12) {
                    Image(systemName: disk.type.uppercased() == "SSD" ? "memorychip" : "internaldrive")
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(disk.name) · \(Format.bytes(disk.size))")
                            .font(.subheadline.weight(.medium))
                        Text([disk.model, disk.pool.map { "pool \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                        Text(disk.smartResult ?? "No SMART test results")
                            .font(.caption2)
                            .foregroundStyle(smartColor(disk.smartResult))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(Format.temperature(disk.temperature))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.temperatureColor(disk.temperature))
                }
            }
        }
    }

    private func smartColor(_ result: String?) -> Color {
        guard let result = result?.lowercased() else { return Theme.secondaryText }
        if result.contains("success") || result.contains("completed without error") { return Theme.good }
        if result.contains("fail") || result.contains("error") { return Theme.danger }
        return Theme.secondaryText
    }

    private var appsCard: some View {
        let running = store.apps.filter(\.isRunning).count
        return Card(title: "Apps", symbol: "square.grid.2x2", trailing: "\(running) of \(store.apps.count) running") {
            ForEach(store.apps) { app in
                HStack(spacing: 12) {
                    AsyncImage(url: app.iconURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "shippingbox").foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.subheadline.weight(.medium))
                        Text(app.ports.isEmpty ? app.version : "Port \(app.ports.map(String.init).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    if app.upgradeAvailable {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.download)
                    }
                    StatusDot(color: app.isRunning ? Theme.good : (app.state.uppercased() == "STOPPED" ? Theme.secondaryText : Theme.warning))
                    Text(app.state.capitalized)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 70, alignment: .leading)
                }
            }
        }
    }
}
