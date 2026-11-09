import Foundation
import Vision
import UIKit

enum OCRServiceError: LocalizedError {
    case recognitionFailed

    var errorDescription: String? {
        "Text recognition failed."
    }
}

struct OCRService {
    func recogniseText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRServiceError.recognitionFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: OCRServiceError.recognitionFailed)
                    return
                }

                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                .joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
