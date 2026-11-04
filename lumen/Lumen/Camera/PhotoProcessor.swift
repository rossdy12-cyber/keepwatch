import AVFoundation
import CoreImage
import Photos
import UIKit

struct SavedPhoto {
    let assetID: String?
    let thumbnail: UIImage?
}

enum CaptureError: LocalizedError {
    case noPhotosAccess
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPhotosAccess: return "Lumen can't save to Photos. Allow it in Settings → Lumen → Photos."
        case .failed(let message): return message
        }
    }
}

/// Collects one capture (RAW and/or processed) and saves it to Photos as a single photo.
final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<SavedPhoto, Error>) -> Void
    private var rawData: Data?
    private var processedData: Data?

    init(completion: @escaping (Result<SavedPhoto, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { rawData = data } else { processedData = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard rawData != nil || processedData != nil else {
            completion(.failure(CaptureError.failed("The photo didn't come out. Try again.")))
            return
        }
        save()
    }

    private func save() {
        let raw = rawData, processed = processedData
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.completion(.failure(CaptureError.noPhotosAccess))
                return
            }
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                if let processed {
                    request.addResource(with: .photo, data: processed, options: nil)
                    // RAW+HEIF: the RAW goes alongside, and the editor uses it.
                    if let raw { request.addResource(with: .alternatePhoto, data: raw, options: nil) }
                } else if let raw {
                    request.addResource(with: .photo, data: raw, options: nil)
                }
                placeholderID = request.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if success {
                    self.completion(.success(SavedPhoto(assetID: placeholderID, thumbnail: Self.thumbnail(processed: processed, raw: raw))))
                } else {
                    self.completion(.failure(error ?? CaptureError.failed("Couldn't save the photo.")))
                }
            }
        }
    }

    private static func thumbnail(processed: Data?, raw: Data?) -> UIImage? {
        if let processed, let image = UIImage(data: processed) {
            return image.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? image
        }
        if let raw, let filter = CIRAWFilter(imageData: raw, identifierHint: nil) {
            filter.scaleFactor = 0.1
            if let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }
}
