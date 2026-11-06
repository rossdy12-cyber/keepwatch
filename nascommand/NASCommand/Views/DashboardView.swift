import SwiftUI

@MainActor
final class DashboardStore: ObservableObject {
    @Published var info: SystemInfo?
    @Published var pools: [NASPool] = []
    @Published var apps: [NASApp] = []
    @Published var alerts: [NASAlert] = []
    @Published var loading = false
    @Published var error: String?
    @Published var busyApp: String?
    @Published var loadedOnce = false

    func load(_ client: TrueNASClient) async {
        loading = true
        error = nil
        do {
            info = try await client.systemInfo()
        } catch {
            self.error = describeError(error)
        }
        pools = (try? await client.pools()) ?? pools
        apps = ((try? await client.apps()) ?? apps).sorted { $0.name.lowercased() < $1.name.lowercased() }
        alerts = ((try? await client.alerts()) ?? alerts).filter { !($0.dismissed ?? false) }
        loading = false
        loadedOnce = true
    }

    func control(_ app: NASApp, _ action: TrueNASClient.AppAction, client: TrueNASClient) async {
        busyApp = app.name
        error = nil
        do {
            try await client.control(app, action)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            apps = ((try? await client.apps()) ?? apps).sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            self.error = describeError(error)
        }
        busyApp = nil
    }
}

struct DashboardView: View {
    var openSettings: () -> Void
    @EnvironmentObject private var settings: NASSettings
    @StateObject private var store = DashboardStore()

    var body: some View {
        NavigationStack {
            Group {
                if !settings.isConfigured {
                    notConfigured
                } else {
                    content
                }
            }
            .navigationTitle("TrueNAS")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { if store.loading { ProgressView() } } }
            .task(id: settings.address + settings.apiKey) {
                if settings.isConfigured { await store.load(settings.client) }
            }
            .refreshable { if settings.isConfigured { await store.load(settings.client) } }
            .background(Theme.background.ignoresSafeArea())
        }
    }

    private var content: some View {
        List {
            if let error = store.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).font(.footnote) }
            }

            Section("System") {
                if let info = store.info {
                    row("Host", info.hostname ?? "—")
                    if let v = info.version { row("Version", v) }
                    if let up = info.uptimeSeconds { row("Uptime", shortUptime(up)) }
                    if let cores = info.cores { row("CPU", "\(cores) cores" + loadSuffix(info.loadavg, cores)) }
                    if let mem = info.physmem { row("Memory", mem.byteSize) }
                    if let model = info.model { row("Model", model).font(.footnote) }
                } else if store.loadedOnce {
                    Text("Couldn't read system info.").foregroundStyle(Theme.secondaryText).font(.footnote)
                }
            }

            Section("Pools") {
                if store.pools.isEmpty && store.loadedOnce {
                    Text("No pools reported.").foregroundStyle(Theme.secondaryText).font(.footnote)
                }
                ForEach(store.pools) { pool in
                    HStack {
                        Image(systemName: "externaldrive.fill").foregroundStyle(Theme.accent)
                        Text(pool.name)
                        Spacer()
                        statusPill(pool.healthy == false ? "DEGRADED" : (pool.status ?? "—"))
                    }
                }
            }

            Section("Apps") {
                if store.apps.isEmpty && store.loadedOnce {
                    Text("No apps reported.").foregroundStyle(Theme.secondaryText).font(.footnote)
                }
                ForEach(store.apps) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            if let v = app.humanVersion { Text(v).font(.caption).foregroundStyle(Theme.secondaryText) }
                        }
                        Spacer()
                        if store.busyApp == app.name {
                            ProgressView()
                        } else {
                            statusPill(app.state ?? "—")
                            appMenu(app)
                        }
                    }
                }
            }

            if !store.alerts.isEmpty {
                Section("Alerts") {
                    ForEach(store.alerts) { alert in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(alertColor(alert.level)).frame(width: 8, height: 8).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.formatted ?? "Alert")
                                if let date = alert.date {
                                    Text(date.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func appMenu(_ app: NASApp) -> some View {
        Menu {
            let running = (app.state ?? "").uppercased() == "RUNNING"
            if running {
                Button { act(app, .stop) } label: { Label("Stop", systemImage: "stop.fill") }
                Button { act(app, .redeploy) } label: { Label("Restart", systemImage: "arrow.clockwise") }
            } else {
                Button { act(app, .start) } label: { Label("Start", systemImage: "play.fill") }
                Button { act(app, .redeploy) } label: { Label("Redeploy", systemImage: "arrow.clockwise") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.accent)
        }
    }

    private func act(_ app: NASApp, _ action: TrueNASClient.AppAction) {
        Task { await store.control(app, action, client: settings.client) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.secondaryText); Spacer(); Text(value).multilineTextAlignment(.trailing) }
    }

    private func statusPill(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.statusColor(status).opacity(0.18), in: Capsule())
            .foregroundStyle(Theme.statusColor(status))
    }

    private func loadSuffix(_ load: [Double]?, _ cores: Int) -> String {
        guard let first = load?.first, cores > 0 else { return "" }
        return String(format: "  ·  %.0f%% load", min(first / Double(cores) * 100, 999))
    }

    private func alertColor(_ level: String?) -> Color {
        switch (level ?? "").uppercased() {
        case "CRITICAL", "ERROR", "ALERT", "EMERGENCY": return Theme.danger
        case "WARNING", "NOTICE": return Theme.warning
        default: return Theme.secondaryText
        }
    }

    private var notConfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(Theme.secondaryText)
            Text("Connect your TrueNAS").font(.headline)
            Text("Add your server address and an API key in Settings.")
                .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
