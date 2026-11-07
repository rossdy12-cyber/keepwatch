import PDFKit
import SwiftUI
import UIKit
import VisionKit

/// Apple's document scanner: finds the page edges, straightens each page, and lets you add several pages.
/// When you're done it builds a multi-page PDF and opens the share sheet to save or send it.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: (URL?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            for index in 0..<scan.pageCount { pages.append(scan.imageOfPage(at: index)) }
            let url = DocumentScannerView.makePDF(pages)
            onFinish(url)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish(nil)
        }
    }

    /// Writes the scanned pages into one PDF file and returns its URL.
    static func makePDF(_ pages: [UIImage]) -> URL? {
        guard !pages.isEmpty else { return nil }
        let document = PDFDocument()
        for (index, image) in pages.enumerated() {
            if let page = PDFPage(image: image) { document.insert(page, at: index) }
        }
        let stamp = Self.stamp()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Scan \(stamp).pdf")
        return document.write(to: url) ? url : nil
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// Whether this iPhone can use the document scanner (needs a camera; always true on a real device).
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }
}
