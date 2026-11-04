import AVFoundation
import AVKit
import CoreMotion
import SwiftUI
import UIKit

/// A press of a volume button or the Camera Control.
enum HardwareButtonPhase { case began, ended, cancelled }

/// The live camera image, with tap-to-focus, long-press AE/AF lock, pinch-to-zoom,
/// and the volume buttons / Camera Control as a shutter.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel
    var hardwareShutter = true
    /// Video: show the whole frame (letterboxed) rather than filling the screen.
    var fit = false
    var onTap: (CGPoint) -> Void
    var onLock: (CGPoint) -> Void = { _ in }
    var onHardwareButton: (HardwareButtonPhase) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(previewLayer: view.previewLayer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.6
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:))))
        if #available(iOS 17.2, *) {
            let coordinator = context.coordinator
            let interaction = AVCaptureEventInteraction { event in
                switch event.phase {
                case .began: coordinator.parent.onHardwareButton(.began)
                case .ended: coordinator.parent.onHardwareButton(.ended)
                default: coordinator.parent.onHardwareButton(.cancelled)
                }
            }
            interaction.isEnabled = hardwareShutter
            view.addInteraction(interaction)
            context.coordinator.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        context.coordinator.parent = self
        let gravity: AVLayerVideoGravity = fit ? .resizeAspect : .resizeAspectFill
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        if #available(iOS 17.2, *), let interaction = context.coordinator.interaction as? AVCaptureEventInteraction {
            interaction.isEnabled = hardwareShutter
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        var interaction: AnyObject?
        private var startZoom: CGFloat = 1

        init(parent: CameraPreview) { self.parent = parent }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewUIView else { return }
            let location = gesture.location(in: view)
            parent.camera.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: location))
            parent.onTap(location)
        }

        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? PreviewUIView else { return }
            let location = gesture.location(in: view)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.camera.lockFocusAndExposure(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: location))
            parent.onLock(location)
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { startZoom = parent.camera.zoom }
            parent.camera.setZoom(startZoom * gesture.scale)
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// The phone's tilt, for the level (and a bubble level when pointing straight down), with a tap when it's level.
final class LevelMonitor: ObservableObject {
    @Published var roll: Double = 0   // degrees; 0 = level
    @Published var flat = false       // pointing straight down or up
    /// Pointing down: how far off flat, −1…1 across and along the screen.
    @Published var tilt = CGPoint.zero
    private let motion = CMMotionManager()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var wasLevel = false

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            self.flat = abs(gravity.z) > 0.9
            // Portrait: level when gravity points straight down the screen. Landscape: along it.
            let angle = atan2(gravity.x, -gravity.y) * 180 / .pi
            let landscape = abs(gravity.x) > abs(gravity.y)
            let roll = landscape ? (angle > 0 ? angle - 90 : angle + 90) : angle
            self.roll = roll
            self.tilt = CGPoint(x: gravity.x, y: -gravity.y)
            let level = self.flat ? (abs(gravity.x) < 0.015 && abs(gravity.y) < 0.015) : abs(roll) < 1
            if level && !self.wasLevel { self.haptic.impactOccurred() }
            self.wasLevel = level
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}

/// Composition guides.
struct GridOverlay: View {
    var style: GridStyle = .thirds

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                func vertical(_ x: CGFloat) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)) }
                func horizontal(_ y: CGFloat) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)) }
                switch style {
                case .off:
                    break
                case .thirds:
                    for i in 1...2 { vertical(w * CGFloat(i) / 3); horizontal(h * CGFloat(i) / 3) }
                case .golden:
                    let phi: CGFloat = 0.382
                    vertical(w * phi); vertical(w * (1 - phi)); horizontal(h * phi); horizontal(h * (1 - phi))
                case .square:
                    let step = w / 4
                    var x = step
                    while x < w - 1 { vertical(x); x += step }
                    var y = h / 2 - step * floor(h / 2 / step)
                    while y < h { if y > 1 { horizontal(y) }; y += step }
                case .crosshair:
                    path.move(to: CGPoint(x: w / 2 - 18, y: h / 2)); path.addLine(to: CGPoint(x: w / 2 + 18, y: h / 2))
                    path.move(to: CGPoint(x: w / 2, y: h / 2 - 18)); path.addLine(to: CGPoint(x: w / 2, y: h / 2 + 18))
                }
            }
            .stroke(Color.white.opacity(style == .crosshair ? 0.8 : 0.35), lineWidth: style == .crosshair ? 1 : 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Darkens what falls outside the chosen photo shape.
struct AspectMask: View {
    let aspect: CaptureAspect

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Portrait: the photo's long side runs down the screen.
            let frameWidth = min(size.width, size.height / aspect.ratio)
            let frameHeight = min(size.height, frameWidth * aspect.ratio)
            let frame = CGRect(x: (size.width - frameWidth) / 2, y: (size.height - frameHeight) / 2, width: frameWidth, height: frameHeight)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
    }
}

/// The live look / false colour / zebras / peaking picture.
struct OverlayImageView: View {
    @ObservedObject var feed: OverlayFeed
    var fit = false

    var body: some View {
        GeometryReader { geometry in
            if let image = feed.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
    }
}

/// Microphone level bars.
struct AudioMeterView: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        if !meter.levels.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "mic.fill").font(.system(size: 9))
                VStack(spacing: 2) {
                    ForEach(Array(meter.levels.prefix(2).enumerated()), id: \.offset) { _, level in
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(level > 0.92 ? Color.red : (level > 0.75 ? Color.yellow : Color.green))
                                    .frame(width: geometry.size.width * CGFloat(level))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .frame(width: 60)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.black.opacity(0.35), in: Capsule())
            .allowsHitTesting(false)
        }
    }
}

/// A horizon line that turns yellow when the phone is level; a bubble level when shooting straight down.
struct LevelOverlay: View {
    @ObservedObject var level: LevelMonitor

    var body: some View {
        if level.flat {
            let centred = abs(level.tilt.x) < 0.015 && abs(level.tilt.y) < 0.015
            ZStack {
                Circle().stroke(Color.white.opacity(0.7), lineWidth: 1).frame(width: 44, height: 44)
                Circle().stroke(Color.white.opacity(0.4), lineWidth: 1).frame(width: 12, height: 12)
                Circle().fill(centred ? Color.yellow : Color.white)
                    .frame(width: 10, height: 10)
                    .offset(x: max(-40, min(40, level.tilt.x * 400)), y: max(-40, min(40, level.tilt.y * 400)))
            }
            .animation(.easeOut(duration: 0.1), value: level.tilt)
            .allowsHitTesting(false)
        } else {
            let isLevel = abs(level.roll) < 1
            HStack(spacing: 0) {
                Capsule().fill(isLevel ? Color.yellow : Color.white.opacity(0.7)).frame(width: 40, height: 2)
                Spacer().frame(width: 16)
                Capsule().fill(isLevel ? Color.yellow : Color.white.opacity(0.7)).frame(width: 40, height: 2)
            }
            .rotationEffect(.degrees(isLevel ? 0 : -level.roll))
            .opacity(abs(level.roll) < 12 ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: level.roll)
            .allowsHitTesting(false)
        }
    }
}

/// The small brightness histogram.
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                guard bins.count > 1 else { return }
                path.move(to: CGPoint(x: 0, y: h))
                for (i, value) in bins.enumerated() {
                    path.addLine(to: CGPoint(x: w * CGFloat(i) / CGFloat(bins.count - 1), y: h - h * CGFloat(value)))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.75))
        }
        .frame(width: 96, height: 44)
        .padding(4)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}

/// The magnified centre of the frame, for focusing by hand.
struct LoupeView: View {
    @ObservedObject var feed: OverlayFeed

    var body: some View {
        if let image = feed.loupe {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow, lineWidth: 1.5))
                .shadow(radius: 6)
                .allowsHitTesting(false)
        }
    }
}

/// Cinema frame lines over the (letterboxed) video frame. Assumes the iPhone is held sideways.
struct FrameGuideMask: View {
    let guide: FrameGuide
    /// The recorded frame's long side ÷ short side, after any anamorphic stretch.
    let frameRatio: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // The video frame, upright in the portrait screen: its long side runs down.
            let videoWidth = min(size.width, size.height / frameRatio)
            let videoHeight = videoWidth * frameRatio
            let video = CGRect(x: (size.width - videoWidth) / 2, y: (size.height - videoHeight) / 2, width: videoWidth, height: videoHeight)
            if let ratio = guide.ratio {
                let width = min(video.width, video.height / ratio)
                let height = min(video.height, width * ratio)
                let frame = CGRect(x: video.midX - width / 2, y: video.midY - height / 2, width: width, height: height)
                Path { path in
                    path.addRect(video)
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The QR code found, as a button; the document outline found, with a Scan button.
struct DetectionOverlay: View {
    @ObservedObject var feed: DetectionFeed
    let onScan: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let quad = feed.document, quad.count == 4, feed.frameSize.width > 0 {
                // The preview fills the screen from the live frame (aspect fill).
                let scale = max(size.width / feed.frameSize.width, size.height / feed.frameSize.height)
                let shown = CGSize(width: feed.frameSize.width * scale, height: feed.frameSize.height * scale)
                let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
                let points = quad.map { CGPoint(x: origin.x + $0.x * shown.width, y: origin.y + $0.y * shown.height) }
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .fill(Color.yellow.opacity(0.15))
                .allowsHitTesting(false)
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .stroke(Color.yellow, lineWidth: 2)
                .allowsHitTesting(false)
                Button(action: onScan) {
                    Label("Scan document", systemImage: "doc.viewfinder")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.yellow, in: Capsule())
                        .foregroundStyle(.black)
                }
                .position(x: size.width / 2, y: size.height - 70)
            } else if let code = feed.code {
                let link = URL(string: code).flatMap { $0.scheme == nil ? nil : $0 }
                Button {
                    if let link { UIApplication.shared.open(link) } else { UIPasteboard.general.string = code }
                } label: {
                    Label(link != nil ? "Open \(link?.host ?? code)" : "Copy “\(code.prefix(40))”",
                          systemImage: link != nil ? "qrcode" : "doc.on.doc")
                        .lineLimit(1)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.yellow, in: Capsule())
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: size.width - 40)
                .position(x: size.width / 2, y: size.height - 70)
            }
        }
    }
}

/// RGB histogram.
struct RGBHistogramView: View {
    let channels: [[Float]]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(channels.enumerated()), id: \.offset) { index, bins in
                    Path { path in
                        let w = geometry.size.width, h = geometry.size.height
                        guard bins.count > 1 else { return }
                        path.move(to: CGPoint(x: 0, y: h))
                        for (i, value) in bins.enumerated() {
                            path.addLine(to: CGPoint(x: w * CGFloat(i) / CGFloat(bins.count - 1), y: h - h * CGFloat(value)))
                        }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill([Color.red, Color.green, Color.blue][min(index, 2)].opacity(0.55))
                    .blendMode(.screen)
                }
            }
        }
        .frame(width: 96, height: 44)
        .padding(4)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}

/// Brightness waveform.
struct WaveformView: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .colorMultiply(Color(red: 0.6, green: 1, blue: 0.6))
            }
            VStack {
                Rectangle().fill(Color.red.opacity(0.5)).frame(height: 0.5)
                Spacer()
            }
        }
        .frame(width: 120, height: 56)
        .padding(4)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}
