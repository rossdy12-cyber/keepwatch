import SwiftUI

/// Draws the companion creature procedurally (no image assets) and animates it: idle bob, blinking, a talking
/// mouth while it speaks, and a gentle pulse while it listens. Reused in the customizer preview and the chat hero.
struct CreatureView: View {
    let style: CreatureStyle
    var activity: CreatureActivity = .idle
    var animated: Bool = true

    var body: some View {
        if animated {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    draw(context, size, t: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            Canvas { context, size in draw(context, size, t: 0) }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: TimeInterval) {
        let d = min(size.width, size.height)
        let body = Color(hex: style.bodyColorHex)
        let belly = body.lightened(0.33)
        let dark = Color.black.opacity(0.78)

        let bob = CGFloat(sin(t * 1.6)) * d * 0.018
        let pulse: CGFloat = activity == .listening ? 1 + CGFloat(sin(t * 4)) * 0.025 : 1
        let cx = size.width / 2
        let cy = size.height / 2 + bob

        // Body size by shape.
        var bw = d * 0.72, bh = d * 0.72
        switch style.bodyShape {
        case .round: break
        case .egg:   bw = d * 0.62; bh = d * 0.80
        case .bean:  bw = d * 0.80; bh = d * 0.66
        case .chonk: bw = d * 0.86; bh = d * 0.60
        }
        bw *= pulse; bh *= pulse
        let bodyRect = CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)

        // Shadow.
        ctx.fill(Path(ellipseIn: CGRect(x: cx - bw * 0.42, y: cy + bh * 0.42, width: bw * 0.84, height: d * 0.08)),
                 with: .color(.black.opacity(0.14)))

        drawAccessoryBehind(ctx, bodyRect: bodyRect, d: d)

        // Body + belly.
        let bodyPath = Path(roundedRect: bodyRect, cornerRadius: min(bw, bh) * 0.5)
        ctx.fill(bodyPath, with: .color(body))
        let bellyRect = CGRect(x: cx - bw * 0.26, y: cy + bh * 0.02, width: bw * 0.52, height: bh * 0.42)
        ctx.fill(Path(ellipseIn: bellyRect), with: .color(belly))

        // Cheeks.
        let cheekY = cy + bh * 0.06
        let cheekR = d * 0.05
        for sx in [-1.0, 1.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: cx + CGFloat(sx) * bw * 0.30 - cheekR, y: cheekY - cheekR,
                                            width: cheekR * 2, height: cheekR * 1.5)),
                     with: .color(Color(hex: "FF9AA8").opacity(0.55)))
        }

        // Eyes.
        let blink = blinkFactor(t)
        let eyeY = cy - bh * 0.10
        let eyeDX = bw * 0.20
        let eyeR = d * 0.075
        for sx in [-1.0, 1.0] {
            drawEye(ctx, center: CGPoint(x: cx + CGFloat(sx) * eyeDX, y: eyeY), r: eyeR, open: blink, dark: dark, d: d)
        }

        // Mouth.
        drawMouth(ctx, center: CGPoint(x: cx, y: cy + bh * 0.16), width: bw * 0.30, t: t, dark: dark)

        drawAccessoryFront(ctx, bodyRect: bodyRect, d: d)
    }

    // MARK: Eyes

    private func blinkFactor(_ t: TimeInterval) -> CGFloat {
        let cycle = t.truncatingRemainder(dividingBy: 3.6)
        if cycle > 3.4 { return max(0.08, abs(cos((cycle - 3.4) / 0.2 * .pi))) }
        return 1
    }

    private func drawEye(_ ctx: GraphicsContext, center: CGPoint, r: CGFloat, open: CGFloat, dark: Color, d: CGFloat) {
        switch style.eyeStyle {
        case .round, .sparkle:
            let h = r * open
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - r * 0.72, y: center.y - h, width: r * 1.44, height: h * 2)),
                     with: .color(.white))
            let pr = r * 0.62
            let ph = pr * open
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - pr * 0.6, y: center.y - ph * 0.9, width: pr * 1.2, height: ph * 1.8)),
                     with: .color(dark))
            if open > 0.6 {
                let hr = r * 0.22
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - hr, y: center.y - ph * 0.7, width: hr, height: hr)),
                         with: .color(.white))
                if style.eyeStyle == .sparkle {
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x + pr * 0.1, y: center.y + ph * 0.1, width: hr * 0.7, height: hr * 0.7)),
                             with: .color(.white.opacity(0.8)))
                }
            }
        case .happy:
            var p = Path()
            p.addArc(center: CGPoint(x: center.x, y: center.y + r * 0.3), radius: r * 0.9,
                     startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            ctx.stroke(p, with: .color(dark), style: StrokeStyle(lineWidth: d * 0.018, lineCap: .round))
        case .sleepy:
            var p = Path()
            p.move(to: CGPoint(x: center.x - r * 0.8, y: center.y))
            p.addQuadCurve(to: CGPoint(x: center.x + r * 0.8, y: center.y),
                           control: CGPoint(x: center.x, y: center.y + r * 0.5 * open))
            ctx.stroke(p, with: .color(dark), style: StrokeStyle(lineWidth: d * 0.016, lineCap: .round))
        }
    }

    // MARK: Mouth

    private func drawMouth(_ ctx: GraphicsContext, center: CGPoint, width: CGFloat, t: TimeInterval, dark: Color) {
        let talk = activity == .talking ? CGFloat(abs(sin(t * 16))) : 0
        if style.mouthStyle == .open || talk > 0.05 {
            let h = max(width * 0.22, width * 0.5 * talk)
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - width * 0.35, y: center.y - h * 0.3, width: width * 0.7, height: h)),
                     with: .color(dark))
            return
        }
        var p = Path()
        switch style.mouthStyle {
        case .smile:
            p.move(to: CGPoint(x: center.x - width * 0.5, y: center.y))
            p.addQuadCurve(to: CGPoint(x: center.x + width * 0.5, y: center.y),
                           control: CGPoint(x: center.x, y: center.y + width * 0.5))
        case .cat:
            p.move(to: CGPoint(x: center.x - width * 0.5, y: center.y))
            p.addQuadCurve(to: CGPoint(x: center.x, y: center.y), control: CGPoint(x: center.x - width * 0.25, y: center.y + width * 0.4))
            p.addQuadCurve(to: CGPoint(x: center.x + width * 0.5, y: center.y), control: CGPoint(x: center.x + width * 0.25, y: center.y + width * 0.4))
        case .neutral:
            p.move(to: CGPoint(x: center.x - width * 0.35, y: center.y))
            p.addLine(to: CGPoint(x: center.x + width * 0.35, y: center.y))
        case .open:
            break
        }
        ctx.stroke(p, with: .color(dark), style: StrokeStyle(lineWidth: width * 0.14, lineCap: .round, lineJoin: .round))
    }

    // MARK: Accessories

    private func drawAccessoryBehind(_ ctx: GraphicsContext, bodyRect: CGRect, d: CGFloat) {
        let cx = bodyRect.midX, top = bodyRect.minY
        switch style.accessory {
        case .antennae:
            for sx in [-1.0, 1.0] {
                var p = Path()
                p.move(to: CGPoint(x: cx + CGFloat(sx) * bodyRect.width * 0.18, y: top + bodyRect.height * 0.1))
                p.addQuadCurve(to: CGPoint(x: cx + CGFloat(sx) * bodyRect.width * 0.30, y: top - d * 0.14),
                               control: CGPoint(x: cx + CGFloat(sx) * bodyRect.width * 0.34, y: top - d * 0.02))
                ctx.stroke(p, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: d * 0.012, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: cx + CGFloat(sx) * bodyRect.width * 0.30 - d * 0.03,
                                                y: top - d * 0.17, width: d * 0.06, height: d * 0.06)),
                         with: .color(Color(hex: style.bodyColorHex).lightened(0.2)))
            }
        case .headphones:
            var band = Path()
            band.addArc(center: CGPoint(x: cx, y: bodyRect.midY - bodyRect.height * 0.1), radius: bodyRect.width * 0.52,
                        startAngle: .degrees(210), endAngle: .degrees(330), clockwise: false)
            ctx.stroke(band, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: d * 0.03, lineCap: .round))
        default: break
        }
    }

    private func drawAccessoryFront(_ ctx: GraphicsContext, bodyRect: CGRect, d: CGFloat) {
        let cx = bodyRect.midX, top = bodyRect.minY
        switch style.accessory {
        case .bow:
            let y = top + d * 0.02, s = d * 0.09
            ctx.fill(Path(ellipseIn: CGRect(x: cx - s * 1.4, y: y - s / 2, width: s * 1.3, height: s)), with: .color(Color(hex: "F0607A")))
            ctx.fill(Path(ellipseIn: CGRect(x: cx + s * 0.1, y: y - s / 2, width: s * 1.3, height: s)), with: .color(Color(hex: "F0607A")))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - s * 0.25, y: y - s * 0.3, width: s * 0.5, height: s * 0.6)), with: .color(Color(hex: "D04A64")))
        case .cap:
            var brim = Path(roundedRect: CGRect(x: cx - bodyRect.width * 0.34, y: top + d * 0.02, width: bodyRect.width * 0.68, height: d * 0.05), cornerRadius: d * 0.025)
            ctx.fill(brim, with: .color(Color(hex: "4A6FA8")))
            var dome = Path(); dome.addArc(center: CGPoint(x: cx, y: top + d * 0.03), radius: bodyRect.width * 0.30, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            ctx.fill(dome, with: .color(Color(hex: "5C83C0")))
        case .flower:
            let y = top + d * 0.03, pr = d * 0.035
            for a in stride(from: 0.0, to: 360.0, by: 72.0) {
                let rad = a * .pi / 180
                ctx.fill(Path(ellipseIn: CGRect(x: cx + bodyRect.width * 0.26 + cos(rad) * pr - pr, y: y + sin(rad) * pr - pr, width: pr * 2, height: pr * 2)), with: .color(Color(hex: "F2B3C8")))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: cx + bodyRect.width * 0.26 - pr * 0.8, y: y - pr * 0.8, width: pr * 1.6, height: pr * 1.6)), with: .color(Color(hex: "F2D24F")))
        case .headphones:
            for sx in [-1.0, 1.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: cx + CGFloat(sx) * bodyRect.width * 0.48 - d * 0.05, y: bodyRect.midY - bodyRect.height * 0.14 - d * 0.05, width: d * 0.1, height: d * 0.12)), with: .color(.black.opacity(0.8)))
            }
        default: break
        }
    }
}
