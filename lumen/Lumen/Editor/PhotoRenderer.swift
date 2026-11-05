import CoreImage
import Foundation
import ImageIO
import UIKit

/// A ready-made look. Each turns an image into the styled version; the editor blends it in by "amount".
struct Look: Identifiable, Equatable {
    let id: String
    let name: String
    let apply: (CIImage) -> CIImage

    static func == (lhs: Look, rhs: Look) -> Bool { lhs.id == rhs.id }

    static let none = Look(id: "none", name: "Natural") { $0 }

    static let all: [Look] = [
        .none,
        Look(id: "vivid", name: "Vivid") { image in
            image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.12, "inputSaturation": 1.08])
        },
        Look(id: "golden", name: "Golden Hour") { image in
            image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 8)])
                .applyingFilter("CIToneCurve", parameters: toneCurve(lift: 0.04, gamma: 0.02, roll: 0.97))
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25])
        },
        Look(id: "teal-orange", name: "Blockbuster") { image in
            splitTone(image, shadows: CIColor(red: 0.0, green: 0.35, blue: 0.4), highlights: CIColor(red: 1.0, green: 0.62, blue: 0.3), strength: 0.22)
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.12, "inputSaturation": 1.05])
        },
        Look(id: "film", name: "Film") { image in
            image.applyingFilter("CIToneCurve", parameters: toneCurve(lift: 0.07, gamma: 0.03, roll: 0.93))
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.86])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6000, y: 6)])
        },
        Look(id: "moody", name: "Moody") { image in
            splitTone(image, shadows: CIColor(red: 0.1, green: 0.2, blue: 0.35), highlights: CIColor(red: 0.95, green: 0.9, blue: 0.8), strength: 0.18)
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.72, "inputContrast": 1.08, "inputBrightness": -0.03])
                .applyingFilter("CIToneCurve", parameters: toneCurve(lift: 0.05, gamma: -0.02, roll: 0.95))
        },
        Look(id: "pastel", name: "Pastel") { image in
            image.applyingFilter("CIToneCurve", parameters: toneCurve(lift: 0.1, gamma: 0.06, roll: 0.98))
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.8, "inputContrast": 0.9])
        },
        Look(id: "chrome", name: "Chrome") { image in image.applyingFilter("CIPhotoEffectChrome") },
        Look(id: "instant", name: "Instant") { image in image.applyingFilter("CIPhotoEffectInstant") },
        Look(id: "process", name: "Cross Process") { image in image.applyingFilter("CIPhotoEffectProcess") },
        Look(id: "mono", name: "Mono") { image in image.applyingFilter("CIPhotoEffectMono") },
        Look(id: "noir", name: "Noir") { image in
            image.applyingFilter("CIPhotoEffectNoir").applyingFilter("CIColorControls", parameters: ["inputContrast": 1.1])
        },
        Look(id: "silver", name: "Silver") { image in
            image.applyingFilter("CIPhotoEffectTonal")
                .applyingFilter("CIToneCurve", parameters: toneCurve(lift: 0.04, gamma: 0.0, roll: 0.96))
        },
    ]

    static func named(_ id: String) -> Look { all.first { $0.id == id } ?? LUTStore.looks.first { $0.id == id } ?? .none }

    /// Built-in looks plus any imported .cube LUTs.
    static var catalog: [Look] { all + LUTStore.looks }

    /// A gentle S-free curve: lifted blacks (lift), mid-tone shift (gamma), rolled-off whites (roll).
    static func toneCurve(lift: Double, gamma: Double, roll: Double) -> [String: Any] {
        [
            "inputPoint0": CIVector(x: 0, y: lift),
            "inputPoint1": CIVector(x: 0.25, y: 0.25 + gamma * 0.6 + lift * 0.4),
            "inputPoint2": CIVector(x: 0.5, y: 0.5 + gamma),
            "inputPoint3": CIVector(x: 0.75, y: 0.75 + gamma * 0.5 - (1 - roll) * 0.4),
            "inputPoint4": CIVector(x: 1, y: roll),
        ]
    }

    /// Tints the shadows and highlights different colours, by brightness.
    static func splitTone(_ image: CIImage, shadows: CIColor, highlights: CIColor, strength: Double) -> CIImage {
        let extent = image.extent
        let luma = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        let shadowLayer = CIImage(color: shadows).cropped(to: extent)
        let highlightLayer = CIImage(color: highlights).cropped(to: extent)
        // Highlights where bright, shadows where dark.
        let toned = highlightLayer.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: shadowLayer, kCIInputMaskImageKey: luma])
        let softLight = toned.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        return softLight.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image, "inputTime": 1 - strength])
    }
}

/// The original photo. RAW files are developed from the sensor data each time, for the most editing room.
enum PhotoSource {
    case raw(Data)
    case image(CIImage)

    init?(data: Data) {
        if Self.looksLikeRAW(data), CIRAWFilter(imageData: data, identifierHint: nil) != nil {
            self = .raw(data)
        } else if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            self = .image(image)
        } else {
            return nil
        }
    }

    /// DNG (and most RAW files) are TIFF-based.
    private static func looksLikeRAW(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4))
        return head == [0x49, 0x49, 0x2A, 0x00] || head == [0x4D, 0x4D, 0x00, 0x2A]
    }

    var isRAW: Bool { if case .raw = self { return true } else { return false } }
}

/// What the on-device AI found in a photo (or a video's first frame). Worked out once, then reused for every render.
struct AIAnalysis {
    /// Apple's auto-enhance corrections, as filter names and settings (rebuilt each time: filters aren't thread-safe).
    var autoFilters: [(name: String, parameters: [String: Any])] = []
    /// White where the main subject is, black elsewhere (preview resolution).
    var subjectMask: CIImage?

    var hasSubject: Bool { subjectMask != nil }
}

/// Applies an EditRecipe to a photo.
enum PhotoRenderer {
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                             .cacheIntermediates: false])

    /// 3-way colour grading kernel: adds each wheel's colour offset, weighted by the pixel's luminance.
    static let gradeKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 lumenGrade(__sample s, vec3 shadow, vec3 mid, vec3 high) {
        vec3 c = s.rgb;
        float L = dot(c, vec3(0.299, 0.587, 0.114));
        float ws = clamp(1.0 - L * 2.0, 0.0, 1.0);
        float wh = clamp(L * 2.0 - 1.0, 0.0, 1.0);
        float wm = clamp(1.0 - ws - wh, 0.0, 1.0);
        c += shadow * ws + mid * wm + high * wh;
        return vec4(clamp(c, 0.0, 1.0), s.a);
    }
    """)

    /// - scale: 1 for full resolution, smaller for the on-screen preview.
    static func render(_ source: PhotoSource, recipe: EditRecipe, scale: CGFloat, analysis: AIAnalysis? = nil) -> CIImage? {
        guard let base = develop(source, recipe: recipe, scale: scale) else { return nil }
        let adjusted = adjust(base, recipe: recipe, scale: scale, analysis: analysis, isRAW: source.isRAW)
        return crop(applyMasks(adjusted, recipe: recipe), recipe: recipe)
    }

    /// Local adjustments: each radial / graduated mask, blended over the photo through its own gradient.
    static func applyMasks(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        var image = input
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let minSide = min(extent.width, extent.height)
        // Normalised (top-left origin) -> Core Image point (bottom-left origin).
        func point(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height)
        }
        let white = CIColor(red: 1, green: 1, blue: 1), black = CIColor(red: 0, green: 0, blue: 0)
        for layer in recipe.masks where layer.hasEffect {
            var mask: CIImage
            switch layer.kind {
            case .radial:
                let outer = max(4, layer.radius * minSide)
                mask = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": point(layer.center),
                    "inputRadius0": outer * 0.35, "inputRadius1": outer,
                    "inputColor0": white, "inputColor1": black])?.outputImage ?? CIImage(color: black)
            case .linear:
                mask = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": point(layer.center), "inputPoint1": point(layer.end),
                    "inputColor0": white, "inputColor1": black])?.outputImage ?? CIImage(color: black)
            }
            mask = mask.cropped(to: extent)
            if layer.invert { mask = mask.applyingFilter("CIColorInvert").cropped(to: extent) }

            var adjusted = image
            if layer.exposure != 0 {
                adjusted = adjusted.applyingFilter("CIExposureAdjust", parameters: ["inputEV": layer.exposure])
            }
            if layer.contrast != 0 || layer.saturation != 0 {
                adjusted = adjusted.applyingFilter("CIColorControls", parameters: [
                    "inputContrast": 1 + layer.contrast * 0.4, "inputSaturation": 1 + layer.saturation])
            }
            if layer.temperature != 0 {
                adjusted = adjusted.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6500 - layer.temperature * 2500, y: 0)])
            }
            if layer.clarity != 0 {
                let radius = max(2, minSide * 0.02)
                adjusted = adjusted.applyingFilter("CIUnsharpMask", parameters: [
                    "inputRadius": radius, "inputIntensity": layer.clarity * 0.7])
            }
            image = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]).cropped(to: extent)
        }
        return image
    }

    /// One video frame: everything except crop, subject pop and background blur.
    static func renderVideoFrame(_ frame: CIImage, recipe: EditRecipe, analysis: AIAnalysis?) -> CIImage {
        var frameRecipe = recipe
        frameRecipe.subjectPop = 0
        frameRecipe.backgroundBlur = 0
        let base = developImage(frame, recipe: frameRecipe)
        return adjust(base, recipe: frameRecipe, scale: 1, analysis: analysis).cropped(to: frame.extent)
    }

    /// RAW development (or exposure and white balance for other photos).
    static func develop(_ source: PhotoSource, recipe: EditRecipe, scale: CGFloat) -> CIImage? {
        switch source {
        case .raw(let data):
            guard let raw = CIRAWFilter(imageData: data, identifierHint: nil) else { return nil }
            raw.scaleFactor = Float(min(1, scale))
            // Exposure and white balance from the RAW data itself: cleaner than adjusting afterwards.
            raw.exposure = Float(recipe.exposure)
            raw.neutralTemperature = raw.neutralTemperature - Float(recipe.temperature) * 2000
            raw.neutralTint = raw.neutralTint + Float(recipe.tint) * 40
            if recipe.noiseReduction > 0 {
                raw.luminanceNoiseReductionAmount = Float(min(1, 0.2 + recipe.noiseReduction * 0.8))
                raw.colorNoiseReductionAmount = Float(min(1, 0.3 + recipe.noiseReduction * 0.7))
            }
            return raw.outputImage
        case .image(let original):
            let scaled = scale < 1 ? original.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : original
            return developImage(scaled, recipe: recipe)
        }
    }

    static func developImage(_ original: CIImage, recipe: EditRecipe) -> CIImage {
        var image = original
        if recipe.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": recipe.exposure])
        }
        if recipe.temperature != 0 || recipe.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - recipe.temperature * 2500, y: recipe.tint * 50)])
        }
        return image
    }

    /// Everything after development: AI, tone, colour, look, detail and effects (not the crop).
    static func adjust(_ developed: CIImage, recipe: EditRecipe, scale: CGFloat, analysis: AIAnalysis?, isRAW: Bool = false) -> CIImage {
        var image = developed
        let fullExtent = image.extent

        // Magic Enhance: Apple's own auto corrections, blended in by strength.
        if recipe.autoEnhance > 0, let filters = analysis?.autoFilters, !filters.isEmpty {
            var enhanced = image
            for step in filters {
                enhanced = enhanced.applyingFilter(step.name, parameters: step.parameters)
            }
            enhanced = enhanced.cropped(to: image.extent)
            image = recipe.autoEnhance >= 0.999 ? enhanced : enhanced.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: image, "inputTime": 1 - recipe.autoEnhance])
        }
        // Reduce noise (RAW files already had it done during development).
        if recipe.noiseReduction > 0, !isRAW {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.01 + recipe.noiseReduction * 0.04, "inputSharpness": 0.4])
                .cropped(to: image.extent)
        }

        // Highlights and shadows.
        if recipe.highlights != 0 || recipe.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, recipe.highlights) * 0.9,
                "inputShadowAmount": recipe.shadows * 0.9,
                "inputRadius": max(1, 6 * scale)])
            if recipe.highlights > 0 {
                image = image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + recipe.highlights * 0.12),
                    "inputPoint4": CIVector(x: 1, y: 1)])
            }
        }
        // Whites, blacks, fade: one tone curve.
        if recipe.whites != 0 || recipe.blacks != 0 || recipe.fade != 0 {
            let black = max(0, recipe.blacks * 0.12) + recipe.fade * 0.18
            let blackX = max(0, -recipe.blacks * 0.12)
            let white = 1 - max(0, -recipe.whites * 0.12) - recipe.fade * 0.06
            let whiteX = 1 - max(0, recipe.whites * 0.12)
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: blackX, y: black),
                "inputPoint1": CIVector(x: 0.25, y: black + (white - black) * 0.25),
                "inputPoint2": CIVector(x: 0.5, y: black + (white - black) * 0.5),
                "inputPoint3": CIVector(x: 0.75, y: black + (white - black) * 0.75),
                "inputPoint4": CIVector(x: whiteX, y: white)])
        }
        // Contrast and saturation.
        if recipe.contrast != 0 || recipe.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1 + recipe.contrast * 0.35, "inputSaturation": 1 + recipe.saturation,
                "inputBrightness": 0])
        }
        if recipe.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": recipe.vibrance])
        }
        // 3-way colour grading (shadows / midtones / highlights), weighted by luminance.
        if recipe.grade.hasEffect, let kernel = gradeKernel {
            func vec(_ wheel: GradeWheel) -> CIVector {
                let o = wheel.offset
                return CIVector(x: o.r, y: o.g, z: o.b)
            }
            if let graded = kernel.apply(extent: image.extent, arguments: [
                image, vec(recipe.grade.shadows), vec(recipe.grade.midtones), vec(recipe.grade.highlights)
            ]) {
                image = graded.cropped(to: image.extent)
            }
        }
        // The look, blended in.
        if recipe.look != Look.none.id, recipe.lookAmount > 0 {
            let styled = Look.named(recipe.look).apply(image).cropped(to: image.extent)
            image = recipe.lookAmount >= 0.999 ? styled : styled.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: image, "inputTime": 1 - recipe.lookAmount])
        }
        // Clarity: local contrast. Sharpness: fine detail.
        if recipe.clarity != 0 {
            let radius = max(2, min(fullExtent.width, fullExtent.height) * 0.02)
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": radius, "inputIntensity": recipe.clarity * 0.6])
        }
        if recipe.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": recipe.sharpness * 0.8, "inputRadius": max(0.5, 1.6 * scale)])
        }
        // Subject pop and background blur, using the subject outline the AI found.
        if (recipe.subjectPop > 0 || recipe.backgroundBlur > 0), let mask = analysis?.subjectMask {
            let extent = image.extent
            let fitted = mask
                .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX - mask.extent.minX * extent.width / mask.extent.width,
                                                   y: extent.minY - mask.extent.minY * extent.height / mask.extent.height))
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(1, min(extent.width, extent.height) * 0.004)])
                .cropped(to: extent)
            var background = image
            if recipe.backgroundBlur > 0 {
                let inverted = fitted.applyingFilter("CIColorInvert")
                background = image.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": inverted, "inputRadius": recipe.backgroundBlur * min(extent.width, extent.height) * 0.025])
                    .cropped(to: extent)
            }
            var subject = image
            if recipe.subjectPop > 0 {
                subject = image
                    .applyingFilter("CIExposureAdjust", parameters: ["inputEV": recipe.subjectPop * 0.35])
                    .applyingFilter("CIVibrance", parameters: ["inputAmount": recipe.subjectPop * 0.3])
                    .applyingFilter("CIUnsharpMask", parameters: [
                        "inputRadius": max(2, min(extent.width, extent.height) * 0.01), "inputIntensity": recipe.subjectPop * 0.5])
                    .cropped(to: extent)
                background = background
                    .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -recipe.subjectPop * 0.3])
                    .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1 - recipe.subjectPop * 0.25])
            }
            image = subject.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: fitted])
                .cropped(to: extent)
        }
        // Vignette.
        if recipe.vignette != 0 {
            let extent = image.extent
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius": hypot(extent.width, extent.height) * 0.42,
                "inputIntensity": recipe.vignette * 0.9,
                "inputFalloff": 0.6])
        }
        // Grain: monochrome noise, overlaid around mid-grey so it only adds texture.
        if recipe.grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let k = recipe.grain * 0.35
            let grainSize = max(1, 1.4 * scale)
            let grain = noise
                .transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
                .cropped(to: image.extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 1)])
            image = grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                .cropped(to: image.extent)
        }
        return image
    }

    /// Straighten, then crop to the chosen shape (always filling the frame, no empty corners).
    static func crop(_ image: CIImage, recipe: EditRecipe) -> CIImage {
        var result = image
        var extent = image.extent
        if recipe.straighten != 0 {
            let radians = recipe.straighten * .pi / 180
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            result = result.transformed(by: rotation)
            // Zoom in just enough that the rotated photo still covers the original frame.
            let c = abs(cos(radians)), s = abs(sin(radians))
            let w = extent.width, h = extent.height
            let zoom = max((w * c + h * s) / w, (w * s + h * c) / h)
            let inset = CGSize(width: w / zoom, height: h / zoom)
            extent = CGRect(x: center.x - inset.width / 2, y: center.y - inset.height / 2, width: inset.width, height: inset.height)
        }
        if let ratio = recipe.aspect.ratio(forLandscape: extent.width >= extent.height) {
            var width = extent.width, height = extent.height
            if width / height > ratio { width = height * ratio } else { height = width / ratio }
            extent = CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
        }
        return result.cropped(to: extent.integral)
    }

    static func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    /// Full-resolution HEIC for saving.
    static func heic(_ image: CIImage, properties: [String: Any]? = nil) -> Data? {
        var origin = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let properties { origin = origin.settingProperties(properties) }
        return context.heifRepresentation(of: origin, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
    }
}
