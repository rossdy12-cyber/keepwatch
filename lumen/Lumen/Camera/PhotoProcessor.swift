import AVFoundation
import CoreImage
import Photos
import UIKit

struct SavedPhoto {
    let assetID: String?
    let thumbnail: UIImage?
    /// Full-size data for re-opening the shot from its thumbnail when there's no Photos asset (Immich-only).
    var editData: Data? = nil
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

/// Collects one capture (RAW and/or processed, a Live Photo's movie, or a quick "proxy" that Photos finishes later)
/// and saves it to Photos as a single photo: tagged with the location, with the shape and look either cropped into
/// the file or added as a revertible Photos edit.
final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let options: SaveOptions
    private let completion: (Result<SavedPhoto, Error>) -> Void
    private var rawData: Data?
    private var processedData: Data?
    private var proxyData: Data?
    private var liveMovie: URL?

    init(options: SaveOptions, completion: @escaping (Result<SavedPhoto, Error>) -> Void) {
        self.options = options
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { rawData = data } else { processedData = data }
    }

    /// The iPhone hands over a quick version now and finishes the full processing in the background (in Photos).
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?, error: Error?) {
        guard error == nil, let data = deferredPhotoProxy?.fileDataRepresentation() else { return }
        proxyData = data
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error == nil { liveMovie = outputFileURL }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard rawData != nil || processedData != nil || proxyData != nil else {
            completion(.failure(CaptureError.failed("The photo didn't come out. Try again.")))
            return
        }
        save()
    }

    private func save() {
        let raw = rawData, captured = processedData, proxy = proxyData, movie = liveMovie
        let options = self.options
        let completion = self.completion
        Task.detached(priority: .userInitiated) {
            var processed = captured
            // Shape and look as a Photos edit for proxies and Live Photos (their files can't be changed);
            // otherwise cropped into the HEIF/JPEG. RAW files always keep the whole sensor.
            let editLater = options.editInPhotos || proxy != nil || movie != nil
            if !editLater, let data = processed, options.allowCrop { processed = PhotoSaver.crop(data, to: options.aspect) }
            var resources: [(PHAssetResourceType, Data)] = []
            if let proxy {
                resources.append((.photoProxy, proxy))
            } else if let processed {
                resources.append((.photo, processed))
                // RAW+HEIF: the RAW goes alongside, and the editor uses it.
                if let raw { resources.append((.alternatePhoto, raw)) }
            } else if let raw {
                resources.append((.photo, raw))
            }
            do {
                let id = try await PhotoSaver.savePhoto(resources, location: options.location, pairedVideo: movie)
                let preview = proxy ?? processed
                let thumbnail = preview.flatMap {
                    PhotoSaver.thumbnail($0, look: options.look, aspect: editLater && options.allowCrop ? options.aspect : .fourThree)
                } ?? Self.rawThumbnail(raw)
                // A proxy isn't a finished image, so only offer re-opening from a real HEIF/JPEG (or RAW).
                let editData = proxy == nil ? (processed ?? raw) : nil
                completion(.success(SavedPhoto(assetID: id, thumbnail: thumbnail, editData: editData)))
                if let id {
                    if editLater {
                        // Live Photos keep their shape: cropping one here would turn off its movie.
                        await PhotoSaver.applyEdits(look: options.look, aspect: movie == nil && options.allowCrop ? options.aspect : .fourThree,
                                                    toAsset: id)
                    } else {
                        await PhotoSaver.applyLook(options.look, toAsset: id)
                    }
                }
            } catch {
                completion(.failure(error))
            }
            if let movie { try? FileManager.default.removeItem(at: movie) }
        }
    }

    private static func rawThumbnail(_ raw: Data?) -> UIImage? {
        guard let raw, let filter = CIRAWFilter(imageData: raw, identifierHint: nil) else { return nil }
        filter.scaleFactor = 0.1
        guard let output = filter.outputImage, let cg = PhotoSaver.context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
