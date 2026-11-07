import Charts
import SwiftUI

struct GlucoDashboardView: View {
    @EnvironmentObject private var store: GlucoStore
    @State private var selectedHours: Int = 6
    private let hourChoices = [3, 6, 12, 24]

    private var filteredReadings: [GlucoseReading] {
        let cutoff = Date().addingTimeInterval(Double(-selectedHours * 3600))
        return store.readings.filter { $0.timestamp >= cutoff }
    }

    private var filteredBoluses: [PumpEvent] {
        let cutoff = Date().addingTimeInterval(Double(-selectedHours * 3600))
        return store.pumpEvents.filter { $0.timestamp >= cutoff && ($0.insulinUnits ?? 0) > 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerBanner
                    dexcomHeroCard
                    tandemStatusCard
                    combinedChartCard
                    timeInRangeCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(GlucoTheme.background)
            .navigationTitle("GlucoPulse")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await store.refreshAll()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.unit = (store.unit == .mmolL) ? .mgdL : .mmolL
                    } label: {
                        Text(store.unit.rawValue)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(GlucoTheme.cardElevated, in: Capsule())
                            .foregroundStyle(GlucoTheme.tandemCyan)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        if store.isSyncing {
                            ProgressView().tint(GlucoTheme.tandemCyan)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    private var headerBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.dexcomConnected || store.tandemConnected ? GlucoTheme.inRangeGreen : GlucoTheme.tandemCyan)
                .frame(width: 8, height: 8)
            Text(store.statusBanner)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GlucoTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text("READ-ONLY")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
                .foregroundStyle(GlucoTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GlucoTheme.border, lineWidth: 1))
    }

    private var dexcomHeroCard: some View {
        let latest = store.latestReading
        let hasReading = (latest != nil)
        let mg = latest?.mgdL ?? 100
        let glucoseColor = hasReading ? store.color(for: mg) : GlucoTheme.tandemCyan
        let minsAgo = latest.map { max(0, Int(Date().timeIntervalSince($0.timestamp) / 60)) } ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                            .foregroundStyle(hasReading ? GlucoTheme.inRangeGreen : GlucoTheme.tandemCyan)
                        Text("DEXCOM G7 CGM")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(GlucoTheme.textSecondary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(hasReading ? store.formatGlucose(mg) : (store.unit == .mmolL ? "--.-" : "---"))
                            .font(.system(size: 54, weight: .black, design: .rounded))
                            .foregroundStyle(glucoseColor)
                        Text(latest?.trend.arrow ?? "—")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(glucoseColor)
                    }

                    HStack(spacing: 10) {
                        Text(hasReading ? "\(store.formatDelta()) \(store.unit.rawValue)" : store.unit.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(glucoseColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(glucoseColor)

                        Text(latest?.trend.label ?? "Waiting for live G7 / Pump BLE…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(GlucoTheme.textPrimary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(hasReading ? (minsAgo == 0 ? "Just now" : "\(minsAgo)m ago") : "Live BLE")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GlucoTheme.textPrimary)
                        Text("5m G7 interval")
                            .font(.system(size: 11))
                            .foregroundStyle(GlucoTheme.textSecondary)
                    }

                    Divider().frame(width: 70)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Target Range")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(GlucoTheme.textSecondary)
                        Text("\(store.formatGlucose(store.lowMgdL))–\(store.formatGlucose(store.highMgdL))")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(GlucoTheme.inRangeGreen)
                    }
                }
            }

            Divider().overlay(GlucoTheme.border)

            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(GlucoTheme.tandemCyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.g7BLEStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GlucoTheme.inRangeGreen)
                        .lineLimit(1)
                    Text(store.tandemBLEStatus)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GlucoTheme.tandemCyan)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    if store.isAlertSnoozed {
                        store.clearAlertSnooze()
                    } else {
                        store.snoozeAlerts(minutes: 60)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.isAlertSnoozed ? "bell.slash.fill" : "bell.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(store.isAlertSnoozed ? "Muted 1h" : "Mute 1h")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((store.isAlertSnoozed ? GlucoTheme.highAmber : Color.white).opacity(0.16), in: Capsule())
                    .foregroundStyle(store.isAlertSnoozed ? GlucoTheme.highAmber : GlucoTheme.textSecondary)
                }
                .fixedSize()

                Button {
                    store.forceBLEPollNow()
                } label: {
                    Text("Read BLE Now")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(GlucoTheme.tandemCyan.opacity(0.22), in: Capsule())
                        .foregroundStyle(GlucoTheme.tandemCyan)
                }
                .fixedSize()
            }
        }
        .padding(18)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(glucoseColor.opacity(0.35), lineWidth: 1.5))
    }

    private var tandemStatusCard: some View {
        let p = store.pumpStatus
        let hasBolus = p.lastBolusUnits > 0 && p.lastBolusDate != .distantPast
        let bolusMinsAgo = hasBolus ? max(0, Int(Date().timeIntervalSince(p.lastBolusDate) / 60)) : 0
        let bolusAgoText: String = {
            guard hasBolus else { return "Waiting for pump BLE" }
            if bolusMinsAgo == 0 { return "Just now" }
            return bolusMinsAgo >= 60
                ? "\(bolusMinsAgo / 60)h \(bolusMinsAgo % 60)m ago"
                : "\(bolusMinsAgo)m ago"
        }()

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "drop.transmission")
                        .foregroundStyle(GlucoTheme.tandemCyan)
                    Text("TANDEM t:slim X2")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(GlucoTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text(p.controlIQMode)
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(GlucoTheme.controlIQPurple.opacity(0.2), in: Capsule())
                .foregroundStyle(GlucoTheme.controlIQPurple)
            }

            if !store.tandemConnected || store.tandemNeedsPairingCode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(GlucoTheme.tandemCyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pump BLE Pairing Code (1-Time Setup)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(GlucoTheme.textPrimary)
                        Text("Pump: Options → Device Settings → Bluetooth → Pair Device")
                            .font(.system(size: 9))
                            .foregroundStyle(GlucoTheme.textSecondary)
                    }
                    Spacer()
                    TextField("6 or 16 char", text: $store.tandemPairingCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(width: 96)
                        .background(GlucoTheme.cardElevated, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(GlucoTheme.tandemCyan)
                    Button {
                        store.submitTandemPairingCode()
                    } label: {
                        Text("Pair")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(GlucoTheme.tandemCyan, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                .padding(10)
                .background(GlucoTheme.cardElevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                pumpTile(
                    title: "Insulin on Board (IOB)",
                    value: String(format: "%.2f U", p.iobUnits),
                    subtitle: "Active rapid-acting",
                    symbol: "drop.fill",
                    color: GlucoTheme.tandemCyan
                )

                pumpTile(
                    title: "Control-IQ Basal",
                    value: String(format: "%.2f U/hr", p.activeBasalRate),
                    subtitle: String(format: "Profile: %.2f U/hr", p.scheduledBasalRate),
                    symbol: "waveform.path.ecg",
                    color: GlucoTheme.controlIQPurple
                )

                pumpTile(
                    title: "Last Bolus",
                    value: String(format: "%.2f U", p.lastBolusUnits),
                    subtitle: bolusAgoText,
                    symbol: "clock.arrow.circlepath",
                    color: GlucoTheme.inRangeGreen
                )

                pumpTile(
                    title: "Pump & Cartridge",
                    value: "\(Int(p.reservoirUnits)) U",
                    subtitle: "Battery: \(p.batteryPercent)%",
                    symbol: "battery.75percent",
                    color: p.batteryPercent < 25 ? GlucoTheme.lowRed : GlucoTheme.highAmber
                )
            }
        }
        .padding(16)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(GlucoTheme.border, lineWidth: 1))
    }

    private func pumpTile(title: String, value: String, subtitle: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GlucoTheme.textSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(GlucoTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(GlucoTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GlucoTheme.cardElevated, in: RoundedRectangle(cornerRadius: 14))
    }

    private static func chartTimeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private var combinedChartCard: some View {
        let lowVal = store.unit == .mmolL ? Double(store.lowMgdL) / 18.0182 : Double(store.lowMgdL)
        let highVal = store.unit == .mmolL ? Double(store.highMgdL) / 18.0182 : Double(store.highMgdL)
        let yMin = store.unit == .mmolL ? 2.0 : 40.0
        let yMax = store.unit == .mmolL ? 20.0 : 360.0
        let windowEnd = Date()
        let windowStart = windowEnd.addingTimeInterval(Double(-selectedHours * 3600))
        let xStrideHours: Int = {
            switch selectedHours {
            case 3: return 1
            case 6: return 1
            case 12: return 2
            default: return 4
            }
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("G7 Glucose & t:slim X2 Timeline (\(selectedHours)h)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(GlucoTheme.textPrimary)
                    Text("\(Self.chartTimeLabel(windowStart)) – \(Self.chartTimeLabel(windowEnd)) · \(filteredReadings.count) readings in \(selectedHours)h window")
                        .font(.system(size: 11))
                        .foregroundStyle(GlucoTheme.textSecondary)
                }
                Spacer()
                Picker("Window", selection: $selectedHours) {
                    ForEach(hourChoices, id: \.self) { h in
                        Text("\(h)h").tag(h)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            Chart {
                RectangleMark(
                    xStart: .value("Start", windowStart),
                    xEnd: .value("End", windowEnd),
                    yStart: .value("Low", lowVal),
                    yEnd: .value("High", highVal)
                )
                .foregroundStyle(GlucoTheme.inRangeGreen.opacity(0.08))

                RuleMark(y: .value("High Target", highVal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(GlucoTheme.highAmber.opacity(0.6))

                RuleMark(y: .value("Low Target", lowVal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(GlucoTheme.lowRed.opacity(0.6))

                ForEach(filteredReadings) { r in
                    let yVal = store.unit == .mmolL ? r.mmolL : Double(r.mgdL)
                    LineMark(
                        x: .value("Time", r.timestamp),
                        y: .value("Glucose", yVal)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(GlucoTheme.inRangeGreen.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 2.2))

                    PointMark(
                        x: .value("Time", r.timestamp),
                        y: .value("Glucose", yVal)
                    )
                    .symbolSize(26)
                    .foregroundStyle(store.color(for: r.mgdL))
                }

                ForEach(filteredBoluses) { ev in
                    PointMark(
                        x: .value("Bolus Time", ev.timestamp),
                        y: .value("Bolus Marker", yMin + (yMax - yMin) * 0.08)
                    )
                    .symbol(.circle)
                    .symbolSize(75)
                    .foregroundStyle(GlucoTheme.tandemCyan)
                    .annotation(position: .top, spacing: 2) {
                        if let u = ev.insulinUnits {
                            Text(String(format: "%.1fU", u))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(GlucoTheme.tandemCyan)
                        }
                    }
                }
            }
            .id(selectedHours)
            .chartXScale(domain: windowStart...windowEnd)
            .chartYScale(domain: yMin...yMax)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: xStrideHours)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.white.opacity(0.12))
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(GlucoTheme.textSecondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedHours)
            .frame(height: 225)
        }
        .padding(16)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(GlucoTheme.border, lineWidth: 1))
    }

    private var timeInRangeCard: some View {
        let tir = store.timeInRangePercent(hours: selectedHours)
        let low = store.timeBelowRangePercent(hours: selectedHours)
        let high = store.timeAboveRangePercent(hours: selectedHours)
        let avg = store.averageMgdL(hours: selectedHours)
        let gmi = store.gmiPercent(hours: selectedHours)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(selectedHours)-Hour Combined Summary")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlucoTheme.textPrimary)
                Spacer()
                Text("\(filteredReadings.count) / \(store.readings.count) G7 readings")
                    .font(.system(size: 11))
                    .foregroundStyle(GlucoTheme.textSecondary)
            }

            GeometryReader { geo in
                HStack(spacing: 3) {
                    if low > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(GlucoTheme.lowRed)
                            .frame(width: max(8, geo.size.width * CGFloat(low) / 100.0))
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(GlucoTheme.inRangeGreen)
                        .frame(width: max(12, geo.size.width * CGFloat(tir) / 100.0))
                    if high > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(GlucoTheme.highAmber)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 12)

            HStack(spacing: 12) {
                summaryStat(label: "In Range", value: "\(tir)%", color: GlucoTheme.inRangeGreen)
                summaryStat(label: "High", value: "\(high)%", color: GlucoTheme.highAmber)
                summaryStat(label: "Low", value: "\(low)%", color: GlucoTheme.lowRed)
                summaryStat(label: "Average", value: store.readings.isEmpty ? "--" : "\(store.formatGlucose(avg))", color: GlucoTheme.textPrimary)
                summaryStat(label: "GMI (A1c)", value: gmi, color: GlucoTheme.tandemCyan)
            }
        }
        .padding(16)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(GlucoTheme.border, lineWidth: 1))
    }

    private func summaryStat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(GlucoTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
