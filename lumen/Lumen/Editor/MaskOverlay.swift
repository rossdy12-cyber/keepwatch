import SwiftUI

/// Draggable handles over the photo for placing a radial or graduated mask.
/// Works in the same coordinate space as the editor's preview image (scaled-to-fit with 8pt padding).
struct MaskOverlay: View {
    @Binding var mask: MaskLayer
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fittedRect(container: geometry.size, image: imageSize, padding: 8)
            ZStack {
                switch mask.kind {
                case .radial:
                    let centre = point(mask.center, in: rect)
                    let r = CGFloat(mask.radius) * min(rect.width, rect.height)
                    Circle()
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: r * 2, height: r * 2)
                        .position(centre)
                    handle.position(centre)
                        .gesture(drag { mask.center = normalised($0, in: rect) })
                    // A handle on the rim to resize.
                    handle.position(x: centre.x + r, y: centre.y)
                        .gesture(DragGesture().onChanged { value in
                            let dx = value.location.x - centre.x, dy = value.location.y - centre.y
                            mask.radius = max(0.03, min(1.2, Double(hypot(dx, dy) / min(rect.width, rect.height))))
                        })
                case .linear:
                    let a = point(mask.center, in: rect), b = point(mask.end, in: rect)
                    Path { $0.move(to: a); $0.addLine(to: b) }
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    // Three parallel guide lines show the fade direction.
                    ForEach([-1.0, 0.0, 1.0], id: \.self) { offset in
                        let n = unit(from: a, to: b)
                        let perp = CGVector(dx: -n.dy, dy: n.dx)
                        let shift = CGFloat(offset) * 40
                        Path {
                            $0.move(to: CGPoint(x: a.x + perp.dx * shift - n.dx * 300, y: a.y + perp.dy * shift - n.dy * 300))
                            $0.addLine(to: CGPoint(x: a.x + perp.dx * shift + n.dx * 300, y: a.y + perp.dy * shift + n.dy * 300))
                        }
                        .stroke(Color.yellow.opacity(offset == 0 ? 0 : 0.25), lineWidth: 0.5)
                    }
                    handle.position(a).gesture(drag { mask.center = normalised($0, in: rect) })
                    handle.position(b).gesture(drag { mask.end = normalised($0, in: rect) })
                }
            }
        }
        .allowsHitTesting(true)
    }

    private var handle: some View {
        Circle().fill(Color.yellow).frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
            .shadow(radius: 2)
    }

    private func drag(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture().onChanged { update($0.location) }
    }

    private func point(_ n: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)
    }

    private func normalised(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)),
                y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }

    private func unit(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.0001, hypot(dx, dy))
        return CGVector(dx: dx / len, dy: dy / len)
    }

    static func fittedRect(container: CGSize, image: CGSize, padding: CGFloat) -> CGRect {
        let avail = CGSize(width: max(1, container.width - padding * 2), height: max(1, container.height - padding * 2))
        guard image.width > 0, image.height > 0 else {
            return CGRect(origin: CGPoint(x: padding, y: padding), size: avail)
        }
        let scale = min(avail.width / image.width, avail.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: padding + (avail.width - size.width) / 2, y: padding + (avail.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }
}
