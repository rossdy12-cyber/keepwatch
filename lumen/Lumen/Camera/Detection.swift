import AVFoundation
import CoreImage
import UIKit
import Vision

extension CameraModel {
    /// Looks for a QR code or a document in a live frame. Runs on the frame queue.
    func detect(in buffer: CVPixelBuffer) {
        let barcodes = VNDetectBarcodesRequest()
        let document = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        try? handler.perform([barcodes, document])
        let code = barcodes.results?.first { $0.payloadStringValue != nil }?.payloadStringValue
        var quad: [CGPoint]?
        if let found = document.results?.first, found.confidence > 0.8 {
            // Vision's corners have the origin at the bottom left; keep both forms.
            quad = [found.topLeft, found.topRight, found.bottomRight, found.bottomLeft]
        }
        scanQuad = quad
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let flipped = quad?.map { CGPoint(x: $0.x, y: 1 - $0.y) }
        DispatchQueue.main.async {
            if self.detection.code != code { self.detection.code = code }
            self.detection.document = code == nil ? flipped : nil
            if self.detection.frameSize != size { self.detection.frameSize = size }
        }
    }

    /// "Scan document": the next live frame, flattened to the page outline and cleaned up.
    func requestDocumentScan() {
        guard !isCapturing else { return }
        isCapturing = true
        stackProgress = 0.5
        videoQueue.async { self.scanRequested = true }
    }

    /// Runs on the frame queue.
    func scanDocument(from buffer: CVPixelBuffer) {
        guard let quad = scanQuad, quad.count == 4 else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.stackProgress = nil
                self.message = "Lost the page. Hold steady and try again."
            }
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        let w = image.extent.width, h = image.extent.height
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        var page = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(quad[0]), "inputTopRight": point(quad[1]),
            "inputBottomRight": point(quad[2]), "inputBottomLeft": point(quad[3])])
        if CIFilter(name: "CIDocumentEnhancer") != nil {
            page = page.applyingFilter("CIDocumentEnhancer", parameters: ["inputAmount": 1])
        }
        let options = DispatchQueue.main.sync { self.saveOptions(withLook: false) }
        let turn = captureRotationFromFrames()
        DispatchQueue.global(qos: .userInitiated).async {
            let upright = StackMath.rotated(page.transformed(by: CGAffineTransform(translationX: -page.extent.minX, y: -page.extent.minY)),
                                            clockwiseDegrees: turn)
            var plain = options
            plain.allowCrop = false
            self.saveRendered(upright, options: plain, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}
