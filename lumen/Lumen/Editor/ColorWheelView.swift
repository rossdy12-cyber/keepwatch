import SwiftUI

/// A colourist's wheel: drag inside the disc to tint a tonal range, and a slider under it sets its brightness.
struct ColorWheelView: View {
    let title: String
    @Binding var x: Double
    @Binding var y: Double
    @Binding var luma: Double
    var size: CGFloat = 104

    private var knobInset: CGFloat { size / 2 - 9 }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            ZStack {
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: wheelColors), center: .center))
                    .overlay(
                        RadialGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.0)],
                                       center: .center, startRadius: 0, endRadius: size / 2)
                    )
                    .clipShape(Circle())
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                knob
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(drag)
            Slider(value: $luma, in: -1...1).tint(.white).frame(width: size)
            Button("Reset") { x = 0; y = 0; luma = 0 }
                .font(.caption2).tint(.yellow)
                .opacity(x == 0 && y == 0 && luma == 0 ? 0.4 : 1)
        }
    }

    private var knob: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
            .shadow(radius: 2)
            .offset(x: CGFloat(x) * knobInset, y: -CGFloat(y) * knobInset)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            let r = size / 2
            var nx = Double((value.location.x - r) / r)
            var ny = Double(-(value.location.y - r) / r)
            let len = (nx * nx + ny * ny).squareRoot()
            if len > 1 { nx /= len; ny /= len }
            x = nx
            y = ny
        }
    }

    private var wheelColors: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map { Color(hue: $0, saturation: 0.85, brightness: 1) }
    }
}
