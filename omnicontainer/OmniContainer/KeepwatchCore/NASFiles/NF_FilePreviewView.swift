import SwiftUI
import QuickLook

struct NFFilePreviewView: View {
    @EnvironmentObject private var settings: NFAppSettings
    @EnvironmentObject private var offlineStore: NFOfflineStore
    @EnvironmentObject private var downloadQueue: NFDownloadQueueService
    @Environment(\.dismiss) private var dismiss

    let file: NFRemoteFile

    @State private var localURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Downloading preview…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let localURL {
                    NFQuickLookPreview(url: localURL)
                } else {
                    ContentUnavailableView("No preview", systemImage: "doc")
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let localURL {
                        ShareLink(item: localURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                if let existing = offlineStore.localURL(for: file),
                   FileManager.default.fileExists(atPath: existing.path) {
                    localURL = existing
                } else {
                    await downloadForPreview()
                }
            }
        }
    }

    private func downloadForPreview() async {
        isLoading = true
        errorMessage = nil

        do {
            let client = NFWebDAVClient(settings: settings)
            let downloadedURL = try await client.download(file)

            var record = offlineStore.createRecord(for: file)
            record.localFileName = downloadedURL.lastPathComponent
            record.state = .downloaded
            record.progress = 100
            record.downloadedAt = Date()
            offlineStore.update(record)

            localURL = downloadedURL
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct NFQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
