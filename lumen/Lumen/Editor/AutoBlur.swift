import CoreImage
import Foundation
import Vision

/// Finds things you might want to hide before sharing — faces, and text blocks like number plates or signs.
/// Returns normalised rectangles (0–1, origin top-left of the upright photo).
enum AutoBlur {
    /// Detected face rectangles, padded a little to cover hair and chin.
    static func faces(in image: CIImage) async -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let observations = await perform(request, on: image) as? [VNFaceObservation] ?? []
        return observations.map { pad(topLeft($0.boundingBox), by: 0.12) }
    }

    /// Text blocks (number plates, signs, labels). Short, boxy pieces of text.
    static func text(in image: CIImage) async -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let observations = await perform(request, on: image) as? [VNRecognizedTextObservation] ?? []
        return observations.map { pad(topLeft($0.boundingBox), by: 0.06) }
    }

    private static func perform(_ request: VNImageBasedRequest, on image: CIImage) async -> [VNObservation]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(ciImage: image, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results as? [VNObservation])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Vision rectangles are normalised with origin bottom-left; flip to top-left.
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.origin.x, y: 1 - box.origin.y - box.height, width: box.width, height: box.height)
    }

    private static func pad(_ rect: CGRect, by fraction: CGFloat) -> CGRect {
        let dx = rect.width * fraction, dy = rect.height * fraction
        let padded = rect.insetBy(dx: -dx, dy: -dy)
        return CGRect(x: max(0, padded.minX), y: max(0, padded.minY),
                      width: min(1, padded.maxX) - max(0, padded.minX),
                      height: min(1, padded.maxY) - max(0, padded.minY))
    }
}
