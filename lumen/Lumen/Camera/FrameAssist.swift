import CoreImage
import SwiftUI

/// The picture drawn over the live preview (a look, false colour, zebras, focus peaking).
/// Kept apart from CameraModel so 20 updates a second only redraw the overlay.
final class OverlayFeed: ObservableObject {
    @Published var image: CGImage?
}

/// Microphone levels, 0–1 per channel.
final class AudioMeter: ObservableObject {
    @Published var levels: [Float] = []
}

struct AssistSettings {
    var look: String = Look.none.id
    var peaking = false
    var zebras = false
    var zebraLevel: CGFloat = 0.95
    var falseColour = false
    var isActive: Bool { look != Look.none.id || peaking || zebras || falseColour }
}

/// Renders the overlay from a live frame. Runs on the frame queue.
final class FrameAssist {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var falseColourCube: Data = Self.cube { luma in Self.falseColour(luma) }
    private var zebraCube: Data?
    private var zebraCubeLevel: CGFloat = -1
    private static let cubeSize = 32

    func render(_ buffer: CVPixelBuffer, settings: AssistSettings) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 720 / max(source.extent.width, 1))
        let frame = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = frame.extent.integral
        let placed = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
        let bounds = CGRect(origin: .zero, size: extent.size)

        var output: CIImage
        if settings.falseColour {
            output = cubed(placed, data: falseColourCube)
        } else if settings.look != Look.none.id {
            output = Look.named(settings.look).apply(placed).cropped(to: bounds)
        } else {
            output = CIImage(color: .clear).cropped(to: bounds)
        }
        if settings.zebras {
            output = zebras(placed, level: settings.zebraLevel, bounds: bounds).composited(over: output)
        }
        if settings.peaking {
            output = peaking(placed, bounds: bounds).composited(over: output)
        }
        return context.createCGImage(output.cropped(to: bounds), from: bounds, format: .RGBA8, colorSpace: sRGB)
    }

    // MARK: Zebras: diagonal stripes over the brightest parts

    private func zebras(_ image: CIImage, level: CGFloat, bounds: CGRect) -> CIImage {
        if zebraCube == nil || zebraCubeLevel != level {
            zebraCube = Self.cube { luma in luma >= Float(level) ? [1, 1, 1, 1] : [0, 0, 0, 0] }
            zebraCubeLevel = level
        }
        let mask = cubed(image, data: zebraCube!)
        let generated = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.85),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputWidth": 4, "inputSharpness": 1])?.outputImage ?? CIImage(color: .white)
        let stripes = generated
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: bounds)
        return stripes.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: bounds)
    }

    // MARK: Focus peaking: sharp edges in red

    private func peaking(_ image: CIImage, bounds: CGRect) -> CIImage {
        let mask = image
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
            .applyingFilter("CIEdges", parameters: ["inputIntensity": 6])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.35])
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 1])
            .applyingFilter("CIMaskToAlpha")
            .cropped(to: bounds)
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: bounds)
        return red.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: bounds)
    }

    // MARK: Colour cubes (worked out on gamma-encoded values, as the eye sees them)

    private func cubed(_ image: CIImage, data: Data) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize, "inputCubeData": data, "inputColorSpace": sRGB])
    }

    /// A colour cube where each colour is replaced by `map(luma)` (premultiplied RGBA).
    private static func cube(_ map: (Float) -> [Float]) -> Data {
        let n = cubeSize
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let luma = 0.2126 * Float(r) / Float(n - 1) + 0.7152 * Float(g) / Float(n - 1) + 0.0722 * Float(b) / Float(n - 1)
                    values.append(contentsOf: map(luma))
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Exposure bands, as on a cinema monitor: purple crushed, blue dark, green mid grey, pink skin, yellow bright, red clipped.
    private static func falseColour(_ luma: Float) -> [Float] {
        let ire = luma * 100
        let grey = luma * 0.8
        switch ire {
        case ..<3: return [0.55, 0.0, 0.75, 1]
        case ..<12: return [0.1, 0.3, 1.0, 1]
        case ..<38: return [grey, grey, grey, 1]
        case ..<48: return [0.15, 0.8, 0.25, 1]
        case ..<55: return [grey, grey, grey, 1]
        case ..<66: return [1.0, 0.55, 0.65, 1]
        case ..<85: return [grey, grey, grey, 1]
        case ..<97: return [1.0, 0.9, 0.1, 1]
        default: return [1.0, 0.1, 0.1, 1]
        }
    }
}
