import SwiftUI
import VisionKit
import PDFKit

struct ScanView: View {
    @EnvironmentObject private var documentStore: DocumentStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploadQueue: UploadQueueService

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category = "Receipt"
    @State private var supplier = ""
    @State private var amount = ""
    @State private var notes = ""
    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var scannerCoordinator: ScannerCoordinator?

    var body: some View {
        NavigationStack {
            Form {
                Section("Document details") {
                    TextField("Title", text: $title)
                    TextField("Category", text: $category)
                    TextField("Supplier", text: $supplier)
                    TextField("Amount", text: $amount)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                Section {
                    Button {
                        presentScanner()
                    } label: {
                        Label("Scan document", systemImage: "doc.text.viewfinder")
                    }
                } footer: {
                    Text("VisionKit will open Apple's document scanner. Scan all pages, then tap Save.")
                }

                if isProcessing {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Processing scanned pages…")
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Label(
                            statusMessage,
                            systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle("New Document")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func presentScanner() {
        guard VNDocumentCameraViewController.isSupported else {
            isError = true
            statusMessage = "Document scanning is not supported on this device."
            return
        }

        let scanner = VNDocumentCameraViewController()
        let coordinator = ScannerCoordinator(parent: self)
        scannerCoordinator = coordinator
        scanner.delegate = coordinator

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else {
            isError = true
            statusMessage = "Unable to open the scanner."
            return
        }

        var presenter: UIViewController? = root

        while let presented = presenter?.presentedViewController {
            presenter = presented
        }

        presenter?.present(scanner, animated: true)
    }

    fileprivate func save(pages: [UIImage]) async {
        isProcessing = true
        isError = false
        statusMessage = nil

        let safeTitle = title.isEmpty ? "Scanned document" : title
        let fileName = "\(Int(Date().timeIntervalSince1970))-\(safeTitle.replacingOccurrences(of: " ", with: "-")).pdf"

        let pdfDocument = PDFDocument()

        for (index, image) in pages.enumerated() {
            if let page = PDFPage(image: image) {
                pdfDocument.insert(page, at: index)
            }
        }

        guard let pdfData = pdfDocument.dataRepresentation() else {
            isProcessing = false
            isError = true
            statusMessage = "Could not create the PDF."
            return
        }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pdfURL = directory.appendingPathComponent(fileName)

        do {
            try pdfData.write(to: pdfURL, options: .atomic)
        } catch {
            isProcessing = false
            isError = true
            statusMessage = error.localizedDescription
            return
        }

        let ocrService = OCRService()
        var ocrText = ""

        for image in pages {
            if let text = try? await ocrService.recogniseText(in: image) {
                ocrText += "\(text)\n"
            }
        }

        let document = ScannedDocument(
            title: safeTitle,
            category: category,
            supplier: supplier,
            amount: amount,
            notes: notes,
            ocrText: ocrText,
            pdfFileName: fileName,
            remotePath: settings.remoteFolder
        )

        documentStore.add(document)
        uploadQueue.enqueue(document)

        isProcessing = false
        statusMessage = "Document saved and queued for upload."
        dismiss()
    }
}

private final class ScannerCoordinator: NSObject, VNDocumentCameraViewControllerDelegate {
    private let parent: ScanView

    init(parent: ScanView) {
        self.parent = parent
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)

        let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }

        Task {
            await parent.save(pages: pages)
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
    }
}
