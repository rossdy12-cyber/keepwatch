import SwiftUI

struct ClockView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0
    private var theme: GothicTheme { store.theme }

    var body: some View {
        VStack(spacing: 16) {
            GothicTitle(text: "Chronometer", theme: theme, size: 26).padding(.top, 50)
            Picker("", selection: $tab) {
                Text("Hour").tag(0); Text("Stopwatch").tag(1); Text("Hourglass").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            Spacer()
            switch tab {
            case 0: ClockFace(theme: theme)
            case 1: Stopwatch(theme: theme)
            default: TimerView(theme: theme)
            }
            Spacer()
        }
    }
}

private struct ClockFace: View {
    let theme: GothicTheme
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 8) {
                Text(ctx.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 60, weight: .light, design: .serif))
                    .foregroundStyle(theme.textColor)
                    .shadow(color: theme.accentColor.opacity(0.4), radius: 10)
                Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(theme.mutedColor)
            }
        }
    }
}

private struct Stopwatch: View {
    let theme: GothicTheme
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var start: Date?

    var body: some View {
        VStack(spacing: 28) {
            TimelineView(.animation(minimumInterval: 0.03, paused: !running)) { ctx in
                let shown = running ? elapsed + (start.map { ctx.date.timeIntervalSince($0) } ?? 0) : elapsed
                Text(fmt(shown))
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                    .foregroundStyle(theme.textColor)
            }
            HStack(spacing: 20) {
                circle("arrow.counterclockwise", filled: false) {
                    running = false; elapsed = 0; start = nil
                }
                circle(running ? "pause.fill" : "play.fill", filled: true) {
                    if running { elapsed += start.map { Date().timeIntervalSince($0) } ?? 0; start = nil }
                    else { start = Date() }
                    running.toggle()
                }
            }
        }
    }
    private func circle(_ s: String, filled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: s).font(.title2)
                .frame(width: 72, height: 72)
                .background(Circle().fill(filled ? theme.accentColor : theme.panelColor))
                .overlay(Circle().strokeBorder(theme.accentColor.opacity(0.4)))
                .foregroundStyle(filled ? .white : theme.textColor)
        }
    }
    private func fmt(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t * 100).truncatingRemainder(dividingBy: 100))
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}

private struct TimerView: View {
    let theme: GothicTheme
    @State private var remaining: TimeInterval = 0
    @State private var running = false
    @State private var endAt: Date?
    @State private var minutes = 5

    var body: some View {
        VStack(spacing: 24) {
            if running, let end = endAt {
                TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                    let left = max(0, end.timeIntervalSince(ctx.date))
                    Text(fmt(left))
                        .font(.system(size: 56, weight: .light, design: .monospaced))
                        .foregroundStyle(left < 10 ? theme.accent2Color : theme.textColor)
                        .onChange(of: left < 0.25) { done in if done { stop() } }
                }
            } else {
                Stepper(value: $minutes, in: 1...180) {
                    Text("\(minutes) min").font(.system(size: 40, weight: .light, design: .serif))
                        .foregroundStyle(theme.textColor)
                }
                .padding(.horizontal, 50)
            }
            Button(running ? "Cease" : "Begin") {
                if running { stop() } else { endAt = Date().addingTimeInterval(Double(minutes) * 60); running = true }
            }
            .font(.system(size: 20, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
            .padding(.horizontal, 40).padding(.vertical, 14)
            .background(Capsule().fill(theme.accentColor))
        }
    }
    private func stop() { running = false; endAt = nil }
    private func fmt(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
