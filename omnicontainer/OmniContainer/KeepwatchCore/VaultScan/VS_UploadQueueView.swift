import SwiftUI

struct VSUploadQueueView: View {
    @EnvironmentObject private var documentStore: VSDocumentStore
    @EnvironmentObject private var settings: VSAppSettings
    @EnvironmentObject private var uploadQueue: VSUploadQueueService

    private var queueDocuments: [VSScannedDocument] {
        documentStore.documents.filter {
            $0.uploadState == .pending || $0.uploadState == .uploading || $0.uploadState == .failed
        }
    }

    var body: some View {
        List {
            if queueDocuments.isEmpty {
                ContentUnavailableView(
                    "No uploads queued",
                    systemImage: "arrow.up.circle",
                    description: Text("New scans are automatically added to the upload queue.")
                )
            } else {
                ForEach(queueDocuments) { document in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.title)
                            .font(.headline)

                        if document.uploadState == .uploading {
                            ProgressView(value: document.uploadProgress, total: 100)
                        }

                        HStack {
                            Text(document.uploadState.displayTitle)
                                .font(.caption)
                                .foregroundStyle(statusColor(document.uploadState))

                            Spacer()

                            if document.retryCount > 0 {
                                Text("Retries: \(document.retryCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = document.lastUploadError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let retry = document.nextRetryAt {
                            Text("Next retry: \(retry.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Uploads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task {
                            await uploadQueue.processAll()
                        }
                    } label: {
                        Label("Process queue", systemImage: "play.circle")
                    }

                    Button {
                        uploadQueue.retryFailed()
                    } label: {
                        Label("Retry failed", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await uploadQueue.processAll()
        }
    }

    private func statusColor(_ state: VSUploadState) -> Color {
        switch state {
        case .pending: return .orange
        case .uploading: return .blue
        case .uploaded: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    VSUploadQueueView()
        .environmentObject(VSAppSettings())
        .environmentObject(VSDocumentStore())
        .environmentObject(VSUploadQueueService(settings: VSAppSettings(), documentStore: VSDocumentStore()))
}
