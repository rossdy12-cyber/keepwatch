import CoreImage
import Vision

/// The on-device AI: Apple's auto-enhance analysis and Vision's subject detection. Nothing leaves the iPhone.
enum AIAnalyser {
    /// - image: the photo at preview size; cgImage: the same, rendered.
    static func analyse(_ image: CIImage, cgImage: CGImage?, findSubject: Bool) -> AIAnalysis {
        var analysis = AIAnalysis()
        analysis.autoFilters = autoFilters(for: image)
        if findSubject, let cgImage {
            analysis.subjectMask = subjectMask(for: cgImage)
        }
        return analysis
    }

    /// Apple's auto-enhance: face-aware tone curve, vibrance and highlight/shadow fixes for this particular photo.
    static func autoFilters(for image: CIImage) -> [(name: String, parameters: [String: Any])] {
        image.autoAdjustmentFilters(options: [.redEye: false]).map { filter in
            var parameters: [String: Any] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                if let value = filter.value(forKey: key) { parameters[key] = value }
            }
            return (filter.name, parameters)
        }
    }

    /// The main subject(s) – people, pets, objects – as a mask the size of the image.
    static func subjectMask(for cgImage: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        } catch {
            return nil
        }
    }
}
