import SwiftUI

fileprivate enum CalcKeyKind { case digit, op, util }

struct CalculatorView: View {
    @EnvironmentObject var store: Store
    @State private var display = "0"
    @State private var accumulator: Double? = nil
    @State private var pendingOp: String? = nil
    @State private var typing = false

    private var theme: GothicTheme { store.theme }

    private let rows: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["0", ".", "="],
    ]

    var body: some View {
        VStack(spacing: 14) {
            GothicTitle(text: "Reckoner", theme: theme, size: 26).padding(.top, 50)
            Spacer()
            Text(display)
                .font(.system(size: 64, weight: .light, design: .serif))
                .foregroundStyle(theme.textColor)
                .lineLimit(1).minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
            VStack(spacing: 12) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 12) {
                        ForEach(rows[r], id: \.self) { key in
                            Button { tap(key) } label: {
                                Text(key)
                                    .font(.system(size: 28, weight: .medium, design: .serif))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 66)
                                    .frame(width: key == "0" ? nil : nil)
                            }
                            .buttonStyle(KeyStyle(theme: theme, kind: kind(of: key), wide: key == "0"))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    fileprivate func kind(of key: String) -> CalcKeyKind {
        if ["÷", "×", "−", "+", "="].contains(key) { return .op }
        if ["C", "±", "%"].contains(key) { return .util }
        return .digit
    }

    private func tap(_ key: String) {
        switch key {
        case "0"..."9":
            if typing { display = display == "0" ? key : display + key }
            else { display = key; typing = true }
        case ".":
            if !display.contains(".") { display += typing ? "." : "0."; typing = true }
        case "C":
            display = "0"; accumulator = nil; pendingOp = nil; typing = false
        case "±":
            if let v = Double(display) { display = fmt(-v) }
        case "%":
            if let v = Double(display) { display = fmt(v / 100) }
        case "÷", "×", "−", "+":
            if let v = Double(display) {
                if let acc = accumulator, let op = pendingOp, typing {
                    accumulator = apply(acc, v, op); display = fmt(accumulator!)
                } else { accumulator = v }
            }
            pendingOp = key; typing = false
        case "=":
            if let acc = accumulator, let op = pendingOp, let v = Double(display) {
                display = fmt(apply(acc, v, op)); accumulator = nil; pendingOp = nil; typing = false
            }
        default: break
        }
    }

    private func apply(_ a: Double, _ b: Double, _ op: String) -> Double {
        switch op {
        case "+": return a + b
        case "−": return a - b
        case "×": return a * b
        case "÷": return b == 0 ? 0 : a / b
        default: return b
        }
    }
    private func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%g", v)
    }
}

private struct KeyStyle: ButtonStyle {
    let theme: GothicTheme
    let kind: CalcKeyKind
    var wide: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = {
            switch kind {
            case .op: return theme.accentColor
            case .util: return theme.panelColor
            case .digit: return theme.panelColor.opacity(0.7)
            }
        }()
        let fg: Color = kind == .op ? .white : theme.textColor
        return configuration.label
            .foregroundStyle(fg)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(kind == .op ? 0 : 0.3), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
