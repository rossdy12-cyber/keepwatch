import SwiftUI
import UIKit

/// Paint over the things you want gone, then send it to the NAS to fill them in with AI.
struct RemoveObjectsView: View {
    let image: UIImage
    /// Normalised strokes (0–1, top-left) and the brush size as a fraction of the shorter side.
    var onRemove: ([[CGPoint]], Double) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var brush: Double = 0.04

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let rect = MaskOverlay.fittedRect(container: geometry.size, image: image.size, padding: 8)
                ZStack {
                    Color.black
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                    Canvas { context, _ in
                        let r = CGFloat(brush) * min(rect.width, rect.height)
                        for stroke in strokes + [current] {
                            let points = stroke.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                            guard let first = points.first else { continue }
                            if points.count == 1 {
                                context.fill(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)),
                                             with: .color(.red.opacity(0.45)))
                            } else {
                                var path = Path()
                                path.move(to: first)
                                for point in points.dropFirst() { path.addLine(to: point) }
                                context.stroke(path, with: .color(.red.opacity(0.45)),
                                               style: StrokeStyle(lineWidth: r * 2, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let n = CGPoint(x: min(1, max(0, (value.location.x - rect.minX) / rect.width)),
                                            y: min(1, max(0, (value.location.y - rect.minY) / rect.height)))
                            current.append(n)
                        }
                        .onEnded { _ in
                            if !current.isEmpty { strokes.append(current); current = [] }
                        }
                )
            }
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: "paintbrush.pointed.fill")
                Slider(value: $brush, in: 0.015...0.12).tint(.yellow)
                Button { if !strokes.isEmpty { strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(strokes.isEmpty)
                Button { strokes = []; current = [] } label: { Image(systemName: "trash") }
                    .disabled(strokes.isEmpty)
            }
            .font(.title3)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    onRemove(strokes, brush)
                    dismiss()
                } label: {
                    Label("Remove", systemImage: "sparkles").fontWeight(.bold)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(strokes.isEmpty ? Color.white.opacity(0.15) : Color.yellow, in: Capsule())
                        .foregroundStyle(strokes.isEmpty ? .white : .black)
                }
                .disabled(strokes.isEmpty)
            }
            Text("Paint over what you want gone, then tap Remove. It's sent to your NAS and filled in with AI.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}
