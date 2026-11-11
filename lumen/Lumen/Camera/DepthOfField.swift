import SwiftUI

/// Depth-of-field for a chosen subject distance — the near/far sharp limits and the hyperfocal distance.
/// Lets you zone-focus like a pro: set the distance, read how much will be acceptably sharp.
struct DoFReading {
    let hyperfocal: Double   // metres
    let near: Double         // metres
    let far: Double          // metres (.infinity once focused at/after hyperfocal)
    var total: Double { far.isInfinite ? .infinity : far - near }
}

enum DoFMath {
    /// focal35: 35mm-equivalent focal length (mm); aperture: f-number; crop: sensor crop factor; distance: subject distance (m).
    static func reading(focal35: Double, aperture: Double, crop: Double, distance: Double) -> DoFReading {
        let fReal = (focal35 / max(crop, 1)) / 1000.0        // real focal length, metres
        let coc = (0.029 / max(crop, 1)) / 1000.0            // circle of confusion, metres (full-frame 0.029 mm ÷ crop)
        let n = max(aperture, 0.95)
        let s = max(distance, fReal * 1.01)
        let h = fReal * fReal / (n * coc) + fReal            // hyperfocal, metres
        let near = s * (h - fReal) / (h + s - 2 * fReal)
        let far: Double = s < h ? s * (h - fReal) / (h - s) : .infinity
        return DoFReading(hyperfocal: h, near: near, far: far)
    }
}

/// A compact "Pro Focus" HUD: focal length, aperture, a subject-distance dial, the sharp range and hyperfocal.
struct DoFGuideView: View {
    @ObservedObject var camera: CameraModel
    @Binding var distance: Double          // metres

    private var reading: DoFReading {
        DoFMath.reading(focal35: camera.focalLength35, aperture: camera.apertureF, crop: camera.sensorCrop, distance: distance)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                tag("\(Int(camera.focalLength35.rounded()))mm")
                tag(String(format: "ƒ/%.1f", camera.apertureF))
                Spacer()
                Text("PRO FOCUS").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.yellow.opacity(0.9))
            }
            scale
            HStack {
                label("NEAR", fmt(reading.near))
                Spacer()
                label("SUBJECT", fmt(distance))
                Spacer()
                label("FAR", reading.far.isInfinite ? "∞" : fmt(reading.far))
            }
            HStack(spacing: 6) {
                Image(systemName: "scope").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Text(reading.total.isInfinite ? "Sharp to infinity" : "Depth of field \(fmt(reading.total))")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("Hyperfocal \(fmt(reading.hyperfocal))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: $distance, in: 0.2...30, step: 0.1).tint(.yellow)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }

    /// A horizontal scale showing where the sharp band (near…far) sits around the subject, on a log distance axis.
    private var scale: some View {
        GeometryReader { geo in
            let w = geo.size.width
            func x(_ d: Double) -> CGFloat {
                let lo = log10(0.2), hi = log10(30.0)
                let clamped = min(max(d, 0.2), 30)
                return CGFloat((log10(clamped) - lo) / (hi - lo)) * w
            }
            let nearX = x(reading.near)
            let farX = reading.far.isInfinite ? w : x(reading.far)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(.yellow.opacity(0.85))
                    .frame(width: max(2, farX - nearX), height: 4)
                    .offset(x: nearX)
                Rectangle().fill(.white).frame(width: 2, height: 14).offset(x: x(distance) - 1)
            }
            .frame(height: 14)
        }
        .frame(height: 14)
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.white.opacity(0.12), in: Capsule())
    }
    private func label(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).tracking(1)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }
    private func fmt(_ m: Double) -> String {
        if m.isInfinite { return "∞" }
        if m < 1 { return String(format: "%.0f cm", m * 100) }
        return String(format: "%.1f m", m)
    }
}
