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
    /// Portrait photos carry depth data, and Live Photos a paired video, which cropping the file would lose.
    var allowCrop = true
    /// Shape and look go on as a Photos edit (revertible) rather than into the file.
    var editInPhotos = false

    var needsEdit: Bool { aspect != .fourThree || look != Look.none.id }
}

final class AssetIDBox {
    var value: String?
}

/// Where new photos and videos are saved.
enum SaveTarget: String, CaseIterable, Identifiable {
    case photos = "Photos library"
    case immich = "Immich (save space)"
    case both = "Both"
    var id: String { rawValue }
    var wantsImmich: Bool { self != .photos }
    var wantsPhotos: Bool { self != .immich }
}

enum PhotoSaver {
    static let context = CIContext()

    /// The chosen save target. Defaults to Immich-only; if Immich isn't set up yet we fall
    /// back to the Photos library so nothing is ever lost (see `effectivePhotosSave`).
    static var saveTarget: SaveTarget { SaveTarget(rawValue: Prefs.string("saveTarget", SaveTarget.immich.rawValue)) ?? .immich }

    static var autoEnhanceOn: Bool { Prefs.bool("autoEnhance", true) }

    /// Apple's on-device auto-enhance (face-aware tone, vibrance, highlight/shadow), baked into a new HEIC.
    /// Returns the enhanced data, or the original if it couldn't be improved. Done in the background after capture,
    /// so it doesn't slow the shutter.
    static func autoEnhanced(_ data: Data) -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        let filters = AIAnalyser.autoFilters(for: image)
        guard !filters.isEmpty else { return data }
        var enhanced = image
        for step in filters { enhanced = enhanced.applyingFilter(step.name, parameters: step.parameters) }
        enhanced = enhanced.cropped(to: image.extent)
        // Blend 65% toward the enhanced version so the auto-adjust is gentle and doesn't amplify noise
        // (a full-strength shadow/contrast boost makes dark, high-ISO shots look grainier).
        enhanced = enhanced.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image, "inputTime": 0.35]).cropped(to: image.extent)
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        return context.heifRepresentation(of: enhanced.settingProperties(properties), format: .RGBA8, colorSpace: space,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]) ?? data
    }

    /// Whether this capture should also go to the Photos library. True when the target asks for
    /// Photos, or when it only asks for Immich but Immich isn't configured (so we keep a copy).
    private static func effectivePhotosSave(_ target: SaveTarget) -> Bool {
        target.wantsPhotos || (target.wantsImmich && !ImmichBackup.shared.isConfigured)
    }

    // MARK: Cropping

    /// The centred rectangle of `extent` with the chosen shape.
    static func cropRect(_ extent: CGRect, aspect: CaptureAspect) -> CGRect {
        let landscape = extent.width >= extent.height
        var width = extent.width, height = extent.height
        if landscape {
            if width / height > aspect.ratio { width = height * aspect.ratio } else { height = width / aspect.ratio }
        } else {
            if height / width > aspect.ratio { height = width * aspect.ratio } else { width = height / aspect.ratio }
        }
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height).integral
    }

    /// Crops a HEIF/JPEG photo to the chosen shape, keeping its metadata. RAW files are left as they are.
    static func crop(_ data: Data, to aspect: CaptureAspect) -> Data {
        guard aspect != .fourThree, let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        let rect = cropRect(image.extent, aspect: aspect)
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1  // the rotation is now part of the pixels
        let cropped = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .settingProperties(properties)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        return context.heifRepresentation(of: cropped, format: .RGBA8, colorSpace: space,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]) ?? data
    }

    // MARK: Saving

    static var albumEnabled: Bool { Prefs.bool("album", true) }

    /// Adds a photo to the library (and the Lumen album, and the NAS backup queue). Returns its Photos ID.
    static func savePhoto(_ resources: [(PHAssetResourceType, Data)], location: CLLocation?, pairedVideo: URL? = nil) async throws -> String? {
        let target = saveTarget
        if target.wantsImmich && ImmichBackup.shared.isConfigured {
            ImmichBackup.shared.add(resources: resources, pairedVideo: pairedVideo)
        }
        // Separate "back up originals to my NAS" feature (independent of the save target).
        NASBackup.shared.add(resources: resources, pairedVideo: pairedVideo)
        // Immich-only (and Immich is set up): don't touch the Photos library at all — saves space, no prompt.
        guard effectivePhotosSave(target) else { return nil }

        let album = albumEnabled ? await lumenAlbum() : nil
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CaptureError.noPhotosAccess }
        let box = AssetIDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for (type, data) in resources { request.addResource(with: type, data: data, options: nil) }
            if let pairedVideo {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: pairedVideo, options: options)
            }
            request.location = location
            if let placeholder = request.placeholderForCreatedAsset {
                box.value = placeholder.localIdentifier
                if let album { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
            }
        }
        return box.value
    }

    static func saveVideo(_ url: URL, location: CLLocation?) async throws {
        let target = saveTarget
        if target.wantsImmich && ImmichBackup.shared.isConfigured { ImmichBackup.shared.add(video: url) }
        NASBackup.shared.add(video: url)
        guard effectivePhotosSave(target) else { return }

        let album = albumEnabled ? await lumenAlbum() : nil
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CaptureError.noPhotosAccess }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: url, options: options)
            request.location = location
            if let album, let placeholder = request.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    /// The "Lumen" album, made the first time (needs full Photos access; without it photos just go to the library).
    static func lumenAlbum() async -> PHAssetCollection? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { return nil }
        if let id = UserDefaults.standard.string(forKey: "lumen.albumID"),
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
            return album
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", "Lumen")
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            UserDefaults.standard.set(existing.localIdentifier, forKey: "lumen.albumID")
            return existing
        }
        let box = AssetIDBox()
        try? await PHPhotoLibrary.shared().performChanges {
            box.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Lumen")
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = box.value else { return nil }
        UserDefaults.standard.set(id, forKey: "lumen.albumID")
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: Revertible edits

    /// Applies the shape and look as a Photos edit: the photo shows them, and Photos' Revert brings the original back.
    static func applyEdits(look: String, aspect: CaptureAspect, toAsset id: String) async {
        guard look != Look.none.id || aspect != .fourThree else { return }
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
        var edited = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if aspect != .fourThree {
            let rect = cropRect(edited.extent, aspect: aspect)
            edited = edited.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        if look != Look.none.id { edited = Look.named(look).apply(edited).cropped(to: edited.extent) }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "app.lumen.look", formatVersion: "2",
                                                 data: Data("\(look)|\(aspect.rawValue)".utf8))
        do {
            try context.writeJPEGRepresentation(of: edited, to: output.renderedContentURL,
                                                colorSpace: original.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!,
                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
        } catch {
            // The original is saved either way.
        }
    }

    static func applyLook(_ look: String, toAsset id: String) async {
        await applyEdits(look: look, aspect: .fourThree, toAsset: id)
    }

    static func thumbnail(_ data: Data, look: String = Look.none.id, aspect: CaptureAspect = .fourThree) -> UIImage? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = 240 / max(image.extent.width, image.extent.height)
        var small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if aspect != .fourThree { small = small.cropped(to: cropRect(small.extent, aspect: aspect)) }
        if look != Look.none.id { small = Look.named(look).apply(small).cropped(to: small.extent) }
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
