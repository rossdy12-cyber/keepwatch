import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var downloadQueue: DownloadQueueService

    var body: some View {
        List {
            Section("Storage") {
                LabeledContent(
                    "Offline storage",
                    value: ByteCountFormatter.string(fromByteCount: offlineStore.storageUsage, countStyle: .file)
                )
            }

            Section("Downloaded files") {
                if offlineStore.files.isEmpty {
                    ContentUnavailableView(
                        "No offline files",
                        systemImage: "arrow.down.circle",
                        description: Text("Download files from the Files tab to make them available offline.")
                    )
                } else {
                    ForEach(offlineStore.files) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.name)
                                .font(.headline)

                            if record.state == .downloading {
                                ProgressView(value: record.progress, total: 100)
                            }

                            HStack {
                                Text(record.state.displayTitle)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(record.state))

                                Spacer()

                                if record.retryCount > 0 {
                                    Text("Retries: \(record.retryCount)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let error = record.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            if let retry = record.nextRetryAt {
                                Text("Next retry: \(retry.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await downloadQueue.retryFailed()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private func statusColor(_ state: DownloadState) -> Color {
        switch state {
        case .pending: return .orange
        case .downloading: return .blue
        case .downloaded: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    DownloadsView()
        .environmentObject(OfflineStore())
        .environmentObject(DownloadQueueService(settings: AppSettings(), offlineStore: OfflineStore()))
}
