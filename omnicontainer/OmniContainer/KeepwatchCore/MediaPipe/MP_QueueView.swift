import SwiftUI

struct MPQueueView: View {
    @EnvironmentObject private var settings: MPAppSettings
    @StateObject private var queueService: MPQueueService

    init() {
        _queueService = StateObject(wrappedValue: MPQueueService(settings: MPAppSettings()))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !settings.isConfigured {
                    ContentUnavailableView(
                        "MeTube not configured",
                        systemImage: "server.rack",
                        description: Text("Add your MeTube server URL in Settings.")
                    )
                } else if queueService.jobs.isEmpty {
                    ContentUnavailableView(
                        queueService.isConnected ? "No active downloads" : "Not connected",
                        systemImage: queueService.isConnected ? "arrow.down.circle" : "antenna.radiowaves.left.and.right.slash",
                        description: Text(
                            queueService.isConnected
                                ? "Submitted downloads will appear here in real time."
                                : "Connect to MeTube to show its live download queue."
                        )
                    )
                } else {
                    List(queueService.jobs) { job in
                        MPQueueRow(job: job)
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MPConnectionBadge(isConnected: queueService.isConnected)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            queueService.connect()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            queueService.clearCompleted()
                        } label: {
                            Label("Clear completed", systemImage: "trash")
                        }

                        NavigationLink {
                            MPDiagnosticsView()
                                .environmentObject(queueService)
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let error = queueService.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.9), in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .onAppear {
                queueService.updateSettings(settings)
                queueService.connect()
            }
            .onDisappear {
                queueService.disconnect()
            }
        }
    }
}

private struct MPQueueRow: View {
    let job: MPDownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(job.title, systemImage: job.outputType.systemImage)
                .font(.headline)
                .lineLimit(2)

            Text(job.url)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let progress = job.progress, job.state == .downloading {
                ProgressView(value: min(max(progress, 0), 100), total: 100)

                HStack {
                    Text("\(Int(progress))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let speed = job.speed {
                        Text(speed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let eta = job.eta {
                        Text("ETA \(eta)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Label(job.state.displayTitle, systemImage: job.state.systemImage)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Spacer()

                Text(job.destination)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let error = job.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch job.state {
        case .pending: return .orange
        case .downloading: return .blue
        case .completed: return .green
        case .error: return .red
        }
    }
}

private struct MPConnectionBadge: View {
    let isConnected: Bool

    var body: some View {
        Label(
            isConnected ? "Live" : "Offline",
            systemImage: isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        )
        .font(.caption)
        .foregroundStyle(isConnected ? .green : .secondary)
    }
}

#Preview {
    MPQueueView()
        .environmentObject(MPAppSettings())
}
