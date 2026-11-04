import CoreImage
import CoreLocation
import ImageIO
import Photos
import UIKit

/// How a new photo is saved: its shape, its location, and a look applied as an edit (the original is kept).
struct SaveOptions {
    var aspect: CaptureAspect = .fourThree
    var location: CLLocation?
    var look: String = Look.none.id
    /// Portrait photos carry depth data, which cropping would drop.
    var allowCrop = true
}

final class AssetIDBox {
    var value: String?
}

enum PhotoSaver {
    static let context = CIContext()

    /// Crops a HEIF/JPEG photo to the chosen shape, keeping its metadata. RAW files are left as they are.
    static func crop(_ data: Data, to aspect: CaptureAspect) -> Data {
        guard aspect != .fourThree, let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        let extent = image.extent
        let landscape = extent.width >= extent.height
        var width = extent.width, height = extent.height
        if landscape {
            if width / height > aspect.ratio { width = height * aspect.ratio } else { height = width / aspect.ratio }
        } else {
            if height / width > aspect.ratio { height = width * aspect.ratio } else { width = height / aspect.ratio }
        }
        let rect = CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height).integral
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1  // the rotation is now part of the pixels
        let cropped = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .settingProperties(properties)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        return context.heifRepresentation(of: cropped, format: .RGBA8, colorSpace: space,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]) ?? data
    }

    /// Adds a photo to the library. Returns its Photos ID.
    static func savePhoto(_ resources: [(PHAssetResourceType, Data)], location: CLLocation?) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CaptureError.noPhotosAccess }
        let box = AssetIDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for (type, data) in resources { request.addResource(with: type, data: data, options: nil) }
            request.location = location
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return box.value
    }

    static func saveVideo(_ url: URL, location: CLLocation?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CaptureError.noPhotosAccess }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
            request.location = location
        }
    }

    /// Applies a look as a Photos edit: the photo shows the look, and Photos' Revert brings the original back.
    static func applyLook(_ look: String, toAsset id: String) async {
        guard look != Look.none.id else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in continuation.resume(returning: input) }
        }
        guard let input, let url = input.fullSizeImageURL, let original = CIImage(contentsOf: url) else { return }
        let image = original.oriented(forExifOrientation: input.fullSizeImageOrientation)
        let placed = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let styled = Look.named(look).apply(placed).cropped(to: placed.extent)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "app.lumen.look", formatVersion: "1", data: Data(look.utf8))
        do {
            try context.writeJPEGRepresentation(of: styled, to: output.renderedContentURL,
                                                colorSpace: original.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!,
                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
        } catch {
            // The original is saved either way.
        }
    }

    static func thumbnail(_ data: Data, look: String = Look.none.id) -> UIImage? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = 240 / max(image.extent.width, image.extent.height)
        var small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if look != Look.none.id { small = Look.named(look).apply(small).cropped(to: small.extent) }
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
