import AVFoundation
import CoreImage
import Vision

/// Merges a run of live frames into one photo: averaged (night, silky water) or brightest-wins (light trails).
/// Runs on the frame queue.
final class FrameStacker {
    enum Blend { case average, lighten }

    let target: Int
    private(set) var count = 0
    private let blend: Blend
    private let align: Bool
    private let onFinish: (CIImage?) -> Void
    private var accumulator: CIImageAccumulator?
    private var reference: CGImage?
    private var referenceScale: CGFloat = 1
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(frames: Int, blend: Blend, align: Bool, onFinish: @escaping (CIImage?) -> Void) {
        target = max(1, frames)
        self.blend = blend
        self.align = align
        self.onFinish = onFinish
    }

    /// Adds a frame. Returns true once enough frames are in.
    func add(_ buffer: CVPixelBuffer) -> Bool {
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        var frame = source
        if align { frame = aligned(source) }
        guard let accumulator else {
            let created = CIImageAccumulator(extent: extent, format: .RGBAh)
            created?.setImage(frame)
            self.accumulator = created
            count = 1
            return count >= target
        }
        count += 1
        let current = accumulator.image()
        switch blend {
        case .average:
            // Running mean: old × (n−1)/n + new × 1/n.
            let weight = 1 / CGFloat(count)
            let added = Self.scaled(frame, by: weight)
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: Self.scaled(current, by: 1 - weight)])
            accumulator.setImage(added.cropped(to: extent))
        case .lighten:
            let lighter = frame.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: current])
            accumulator.setImage(lighter.cropped(to: extent))
        }
        return count >= target
    }

    func finish() {
        onFinish(accumulator?.image())
    }

    static func scaled(_ image: CIImage, by weight: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)])
    }

    /// Shifts a hand-held frame to line up with the first one.
    private func aligned(_ frame: CIImage) -> CIImage {
        let scale = 384 / max(frame.extent.width, 1)
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let reference else {
            self.reference = context.createCGImage(small, from: small.extent)
            referenceScale = scale
            return frame
        }
        guard let shift = StackMath.translation(of: small, toMatch: reference) else { return frame }
        return frame.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: shift.x / referenceScale, y: shift.y / referenceScale))
            .cropped(to: frame.extent)
    }
}

enum StackMath {
    /// How far `image` must move to line up with `reference` (in `image`'s pixels).
    static func translation(of image: CIImage, toMatch reference: CGImage) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: image, options: [:])
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
            let transform = observation.alignmentTransform
            return CGPoint(x: transform.tx, y: transform.ty)
        } catch {
            return nil
        }
    }

    /// Lines `image` up with `reference` (both full size).
    static func align(_ image: CIImage, to reference: CIImage, context: CIContext) -> CIImage {
        let scale = 512 / max(reference.extent.width, 1)
        let smallReference = reference.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgReference = context.createCGImage(smallReference, from: smallReference.extent),
              let shift = translation(of: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), toMatch: cgReference)
        else { return image }
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: shift.x / scale, y: shift.y / scale))
            .cropped(to: image.extent)
    }

    /// Turns a frame clockwise by a multiple of 90° and moves it back to the origin.
    static func rotated(_ image: CIImage, clockwiseDegrees degrees: CGFloat) -> CIImage {
        let quarter = Int((degrees / 90).rounded()) % 4
        let turns = (quarter + 4) % 4
        guard turns != 0 else { return image }
        // Core Image's y axis points up, so a negative angle turns clockwise.
        let turned = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
    }

    /// Exposure-bracket merge: shadows from the bright shot, highlights from the dark one, the rest from the normal one.
    static func mergeHDR(dark: CIImage, normal: CIImage, bright: CIImage, context: CIContext) -> CIImage {
        let extent = normal.extent
        let alignedDark = align(dark, to: normal, context: context)
        let alignedBright = align(bright, to: normal, context: context)
        let grey = normal.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        let softness = max(2, min(extent.width, extent.height) * 0.006)
        let highlights = grey.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.45, y: 0),
            "inputPoint2": CIVector(x: 0.7, y: 0.5), "inputPoint3": CIVector(x: 0.85, y: 0.9),
            "inputPoint4": CIVector(x: 1, y: 1)])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": softness]).cropped(to: extent)
        let shadows = grey.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 1), "inputPoint1": CIVector(x: 0.04, y: 0.85),
            "inputPoint2": CIVector(x: 0.12, y: 0.45), "inputPoint3": CIVector(x: 0.25, y: 0),
            "inputPoint4": CIVector(x: 1, y: 0)])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": softness]).cropped(to: extent)
        let lifted = alignedBright.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: normal, kCIInputMaskImageKey: shadows])
        let merged = alignedDark.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: lifted, kCIInputMaskImageKey: highlights])
        return merged
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.12])
            .cropped(to: extent)
    }
}

/// Collects an exposure bracket (several photos from one press).
final class BracketProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private var frames: [(bias: Float, data: Data)] = []
    private let completion: ([(bias: Float, data: Data)], Error?) -> Void

    init(completion: @escaping ([(bias: Float, data: Data)], Error?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        var bias = Float(frames.count)
        if let auto = photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings {
            bias = auto.exposureTargetBias
        } else if let manual = photo.bracketSettings as? AVCaptureManualExposureBracketedStillImageSettings {
            bias = Float(manual.exposureDuration.seconds) * manual.iso
        }
        frames.append((bias, data))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(frames.sorted { $0.bias < $1.bias }, error)
    }
}
