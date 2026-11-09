import SwiftUI

struct VSDocumentListView: View {
    @EnvironmentObject private var documentStore: VSDocumentStore
    @EnvironmentObject private var settings: VSAppSettings
    @EnvironmentObject private var uploadQueue: VSUploadQueueService

    @State private var searchText = ""
    @State private var showNewScan = false

    private var filteredDocuments: [VSScannedDocument] {
        guard !searchText.isEmpty else {
            return documentStore.documents
        }

        return documentStore.documents.filter {
            $0.searchableText.contains(searchText.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if documentStore.documents.isEmpty {
                    ContentUnavailableView(
                        "No documents",
                        systemImage: "doc.text.viewfinder",
                        description: Text("Scan a receipt, manual, warranty, or invoice to get started.")
                    )
                } else if filteredDocuments.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredDocuments) { document in
                        NavigationLink(value: document.id) {
                            VSDocumentRow(document: document)
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { documentID in
                if let document = documentStore.documents.first(where: { $0.id == documentID }) {
                    VSDocumentDetailView(document: document)
                }
            }
            .searchable(text: $searchText, prompt: "Search title, OCR text, supplier, tags, or notes")
            .navigationTitle("VaultScan")
            .sheet(isPresented: $showNewScan) {
                VSScanView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await uploadQueue.processAll()
                        }
                    } label: {
                        if uploadQueue.isProcessing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle")
                        }
                    }
                    .disabled(!settings.isConfigured || uploadQueue.isProcessing)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showNewScan = true
                        } label: {
                            Label("New scan", systemImage: "plus")
                        }

                        NavigationLink {
                            VSUploadQueueView()
                        } label: {
                            Label("Uploads", systemImage: "arrow.up.circle")
                        }

                        ShareLink(
                            item: VSCSVExporter.csv(for: documentStore.documents),
                            preview: SharePreview("VaultScan export")
                        ) {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

private struct VSDocumentRow: View {
    let document: VSScannedDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.title)
                .font(.headline)

            Text("\(document.category) • \(document.documentDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if document.uploadState == .uploading {
                ProgressView(value: document.uploadProgress, total: 100)
            }

            HStack {
                Label(document.uploadState.displayTitle, systemImage: uploadIcon)
                    .font(.caption)
                    .foregroundStyle(uploadColor)

                Spacer()

                if document.retryCount > 0 {
                    Text("Retries: \(document.retryCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !document.tags.isEmpty {
                Text(document.tags.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var uploadIcon: String {
        switch document.uploadState {
        case .pending: return "clock"
        case .uploading: return "arrow.up.circle"
        case .uploaded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var uploadColor: Color {
        switch document.uploadState {
        case .pending: return .orange
        case .uploading: return .blue
        case .uploaded: return .green
        case .failed: return .red
        }
    }
}
