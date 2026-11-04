import AVFoundation
import CoreMotion
import SwiftUI
import UIKit

/// The live camera image, with tap-to-focus and pinch-to-zoom.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(previewLayer: view.previewLayer)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:))))
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        private var startZoom: CGFloat = 1

        init(parent: CameraPreview) { self.parent = parent }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewUIView else { return }
            let location = gesture.location(in: view)
            parent.camera.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: location))
            parent.onTap(location)
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

/// Rule-of-thirds lines.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                for i in 1...2 {
                    path.move(to: CGPoint(x: w * CGFloat(i) / 3, y: 0))
                    path.addLine(to: CGPoint(x: w * CGFloat(i) / 3, y: h))
                    path.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 3))
                    path.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 3))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
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
