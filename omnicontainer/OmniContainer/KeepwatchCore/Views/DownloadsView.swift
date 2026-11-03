import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var router: AppRouter

    @State private var status: DownloadStatus?
    @State private var queue: [QueueItem] = []
    @State private var history: [HistoryItem] = []
    @State private var error: String?
    @State private var busy = false

    private var configured: Bool { settings[.nzbget].isConfigured }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !configured {
                        MessageCard(symbol: "arrow.down.circle", title: "Connect NZBGet",
                                    message: "Add NZBGet's address and its control username and password in Settings.",
                                    color: Theme.accent, actionTitle: "Open Settings") { router.tab = .settings }
                    } else {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.warning)
                        }
                        if let status {
                            statusCard(status)
                        } else if error == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        if status != nil {
                            queueSection
                            historySection
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
            .navigationTitle("Downloads")
            .keepwatchChrome()
        }
        .task(id: settings[.nzbget]) {
            // The queue changes quickly, so it refreshes every 5 seconds while this tab is open.
            while !Task.isCancelled {
                if configured { await load() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func statusCard(_ status: DownloadStatus) -> some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.paused ? "Paused" : (status.rate > 0 ? "Downloading" : "Idle"))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(status.paused ? Theme.warning : Theme.secondaryText)
                    Text(Format.rate(status.rate))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Format.megabytes(status.remainingMB)) left" +
                         (status.rate > 0 ? " · about \(Format.duration(status.remainingMB * 1024 * 1024 / status.rate))" : ""))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    if let free = status.freeDiskMB {
                        Text("\(Format.megabytes(free)) free on the download disk")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Button {
                    Task { await setPaused(!status.paused) }
                } label: {
                    Image(systemName: status.paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(status.paused ? Theme.accent : Theme.surfaceRaised, in: Circle())
                        .foregroundStyle(status.paused ? Color.black : Color.white)
                }
                .disabled(busy)
                .accessibilityLabel(status.paused ? "Resume all downloads" : "Pause all downloads")
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Queue", trailing: queue.isEmpty ? nil : "\(queue.count)")
            if queue.isEmpty {
                Text("Nothing in the queue.")
                    .foregroundStyle(Theme.secondaryText)
                    .font(.subheadline)
            }
            ForEach(queue) { item in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Spacer()
                            Button {
                                Task { await setPaused(!item.isPaused, id: item.id) }
                            } label: {
                                Image(systemName: item.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(item.isPaused ? Theme.accent : Theme.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                        MeterBar(fraction: item.progress, color: item.isPaused ? Theme.warning : Theme.download, height: 6)
                        HStack {
                            Text("\(Format.megabytes(item.sizeMB - item.remainingMB)) of \(Format.megabytes(item.sizeMB))")
                            Spacer()
                            if !item.category.isEmpty { Pill(text: item.category, color: Theme.accent) }
                            Text(item.status.capitalized.replacingOccurrences(of: "_", with: " "))
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "History")
            Card {
                if history.isEmpty {
                    Text("No finished downloads yet.")
                        .foregroundStyle(Theme.secondaryText)
                        .font(.subheadline)
                }
                ForEach(history.prefix(40)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(item.succeeded ? Theme.good : Theme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline)
                                .lineLimit(2)
                            Text([Format.megabytes(item.sizeMB), item.category, Format.relative(item.date),
                                  item.succeeded ? "" : item.status]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private func makeClient() throws -> NZBGetClient {
        try NZBGetClient(config: settings[.nzbget])
    }

    private func load() async {
        do {
            let client = try makeClient()
            async let newStatus = client.status()
            async let newQueue = client.queue()
            async let newHistory = client.history()
            status = try await newStatus
            queue = try await newQueue
            history = try await newHistory
            error = nil
        } catch {
            if !isCancellation(error) { self.error = describe(error) }
        }
    }

    private func setPaused(_ paused: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try await makeClient().setPaused(paused)
            await load()
        } catch {
            self.error = describe(error)
        }
    }

    private func setPaused(_ paused: Bool, id: Int) async {
        busy = true
        defer { busy = false }
        do {
            try await makeClient().setPaused(paused, id: id)
            await load()
        } catch {
            self.error = describe(error)
        }
    }
}
