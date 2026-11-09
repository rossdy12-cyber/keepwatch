import SwiftUI
import PDFKit

struct DocumentDetailView: View {
    @EnvironmentObject private var documentStore: DocumentStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploadQueue: UploadQueueService

    let document: ScannedDocument

    @State private var editedDocument: ScannedDocument?
    @State private var tagsText = ""
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section("Document") {
                if let document = editedDocument {
                    TextField("Title", text: Binding(
                        get: { document.title },
                        set: { editedDocument?.title = $0 }
                    ))

                    TextField("Category", text: Binding(
                        get: { document.category },
                        set: { editedDocument?.category = $0 }
                    ))

                    TextField("Supplier", text: Binding(
                        get: { document.supplier },
                        set: { editedDocument?.supplier = $0 }
                    ))

                    TextField("Amount", text: Binding(
                        get: { document.amount },
                        set: { editedDocument?.amount = $0 }
                    ))

                    TextField("Notes", text: Binding(
                        get: { document.notes },
                        set: { editedDocument?.notes = $0 }
                    ), axis: .vertical)

                    TextField("Tags (comma separated)", text: $tagsText)
                }
            }

            Section("OCR text") {
                if let document = editedDocument {
                    Text(document.ocrText.isEmpty ? "No text recognised." : document.ocrText)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            Section("Upload") {
                Label(document.uploadState.displayTitle, systemImage: "arrow.up.circle")
                    .foregroundStyle(uploadColor)

                if document.uploadState == .uploading {
                    ProgressView(value: document.uploadProgress, total: 100)
                }

                if let error = document.lastUploadError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    guard let document = editedDocument else { return }

                    Task {
                        await uploadQueue.upload(document)
                    }
                } label: {
                    Label("Upload now", systemImage: "arrow.up.to.line")
                }
                .disabled(!settings.isConfigured || uploadQueue.isProcessing)
            }

            Section("PDF") {
                if let url = documentStore.localPDFURL(for: document) as URL?,
                   let pdfDocument = PDFDocument(url: url) {
                    PDFKitView(document: pdfDocument)
                        .frame(minHeight: 400)
                } else {
                    Text("PDF preview unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(document.title)
        .onAppear {
            editedDocument = document
            tagsText = document.tags.joined(separator: ", ")
        }
        .onDisappear {
            if var editedDocument {
                editedDocument.tags = tagsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                documentStore.update(editedDocument)
            }
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isError ? .red.opacity(0.9) : .green.opacity(0.9), in: Capsule())
                    .padding(.bottom, 16)
            }
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

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}
