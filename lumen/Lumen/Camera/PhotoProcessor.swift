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

/// Collects one capture (RAW and/or processed) and saves it to Photos as a single photo:
/// cropped to the chosen shape, tagged with the location, then given the chosen look as a revertible edit.
final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let options: SaveOptions
    private let completion: (Result<SavedPhoto, Error>) -> Void
    private var rawData: Data?
    private var processedData: Data?

    init(options: SaveOptions, completion: @escaping (Result<SavedPhoto, Error>) -> Void) {
        self.options = options
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
        let raw = rawData
        let captured = processedData
        let options = self.options
        let completion = self.completion
        Task.detached(priority: .userInitiated) {
            var processed = captured
            // RAW files keep the whole sensor; the HEIF/JPEG is cropped to the chosen shape.
            if let data = processed, options.allowCrop { processed = PhotoSaver.crop(data, to: options.aspect) }
            var resources: [(PHAssetResourceType, Data)] = []
            if let processed {
                resources.append((.photo, processed))
                // RAW+HEIF: the RAW goes alongside, and the editor uses it.
                if let raw { resources.append((.alternatePhoto, raw)) }
            } else if let raw {
                resources.append((.photo, raw))
            }
            do {
                let id = try await PhotoSaver.savePhoto(resources, location: options.location)
                let thumbnail = processed.flatMap { PhotoSaver.thumbnail($0, look: options.look) } ?? Self.rawThumbnail(raw)
                completion(.success(SavedPhoto(assetID: id, thumbnail: thumbnail)))
                if let id { await PhotoSaver.applyLook(options.look, toAsset: id) }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func rawThumbnail(_ raw: Data?) -> UIImage? {
        guard let raw, let filter = CIRAWFilter(imageData: raw, identifierHint: nil) else { return nil }
        filter.scaleFactor = 0.1
        guard let output = filter.outputImage, let cg = PhotoSaver.context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
