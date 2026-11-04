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

/// The phone's tilt, for the level.
final class LevelMonitor: ObservableObject {
    @Published var roll: Double = 0   // degrees; 0 = level
    @Published var flat = false       // pointing straight down or up
    private let motion = CMMotionManager()

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

    var body: some View {
        GeometryReader { geometry in
            if let image = feed.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
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

/// A horizon line that turns yellow when the phone is level.
struct LevelOverlay: View {
    @ObservedObject var level: LevelMonitor

    var body: some View {
        let isLevel = abs(level.roll) < 1
        HStack(spacing: 0) {
            Capsule().fill(isLevel ? Color.yellow : Color.white.opacity(0.7)).frame(width: 40, height: 2)
            Spacer().frame(width: 16)
            Capsule().fill(isLevel ? Color.yellow : Color.white.opacity(0.7)).frame(width: 40, height: 2)
        }
        .rotationEffect(.degrees(isLevel ? 0 : -level.roll))
        .opacity(level.flat ? 0 : (abs(level.roll) < 12 ? 1 : 0))
        .animation(.easeOut(duration: 0.15), value: level.roll)
        .allowsHitTesting(false)
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
