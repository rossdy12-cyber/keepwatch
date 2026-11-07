import SwiftUI
import WebKit

struct GlucoPumpHistoryView: View {
    @EnvironmentObject private var store: GlucoStore
    @State private var showingQuickLog = false
    @State private var showingTandemPortal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    bleProximityCard
                    tandemSummaryStrip
                    eventsListSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(GlucoTheme.background)
            .navigationTitle("t:slim X2 & G7 Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingTandemPortal = true
                    } label: {
                        Label("Tandem Source", systemImage: "globe")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingQuickLog = true
                    } label: {
                        Label("Log Event", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingQuickLog) {
                QuickLogPumpSheet()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingTandemPortal) {
                TandemPortalSheet()
            }
        }
    }

    private var bleProximityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(GlucoTheme.tandemCyan)
                    Text("DIRECT G7 BLUETOOTH LE GATT + PUMP MONITOR")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(GlucoTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        store.forceBLEPollNow()
                    } label: {
                        Text("Read Now")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(GlucoTheme.inRangeGreen, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Button {
                        store.toggleBLEScan()
                    } label: {
                        Text(store.bleScanning ? "Stop Scan" : "Scan BLE")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(store.bleScanning ? GlucoTheme.lowRed : GlucoTheme.tandemCyan, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }

            Text(store.g7BLEStatus)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GlucoTheme.inRangeGreen)

            HStack(spacing: 8) {
                Image(systemName: "key.radiowaves.forward.fill")
                    .foregroundStyle(GlucoTheme.highAmber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("4-Digit G7 Pairing Code (Standalone BLE)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GlucoTheme.textPrimary)
                    Text("Tandem Pump: Options → My CGM → Pairing Code")
                        .font(.system(size: 10))
                        .foregroundStyle(GlucoTheme.textSecondary)
                }
                Spacer()
                TextField("4-digit code", text: $store.g7PairingCode)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 96)
                    .background(GlucoTheme.cardElevated, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(GlucoTheme.inRangeGreen)
            }
            .padding(10)
            .background(GlucoTheme.cardElevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                if store.bleScanning {
                    let mins = store.bleScanElapsedSeconds / 60
                    let secs = store.bleScanElapsedSeconds % 60
                    Text(String(format: "Scan time: %02d:%02d / 05:00 (G7 wakes for 2s every 5m)", mins, secs))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(GlucoTheme.highAmber)
                }
                Spacer()
                Toggle("Show All BLE", isOn: $store.showAllBLEDevices)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GlucoTheme.textSecondary)
                    .fixedSize()
            }

            if store.bleDevices.isEmpty {
                Text(store.bleScanning
                     ? "Listening for Dexcom G7 (0x00D0 / FEBC / DXCM) & Tandem t:slim X2… Keep screen open for up to 5 mins to catch the G7's 2-second wake pulse, or toggle 'Show All BLE' to inspect all nearby devices."
                     : "Tap 'Scan BLE' to attach to your Dexcom G7 sensor and Tandem t:slim X2 pump.")
                    .font(.system(size: 12))
                    .foregroundStyle(GlucoTheme.textSecondary)
            } else {
                ForEach(store.bleDevices) { dev in
                    Button {
                        store.connectToBLEDevice(id: dev.id)
                    } label: {
                        HStack {
                            Image(systemName: dev.category.contains("Dexcom") ? "sensor.tag.radiowaves.forward.fill" : "drop.transmission")
                                .foregroundStyle(dev.category.contains("Dexcom") ? GlucoTheme.inRangeGreen : GlucoTheme.tandemCyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dev.category) · \(dev.name)")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(GlucoTheme.textPrimary)
                                Text("Last packet: \(Self.timeString(dev.lastSeen)) · Tap to lock/connect")
                                    .font(.system(size: 11))
                                    .foregroundStyle(GlucoTheme.textSecondary)
                            }
                            Spacer()
                            Text("\(dev.rssi) dBm")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(GlucoTheme.cardElevated, in: Capsule())
                                .foregroundStyle(GlucoTheme.inRangeGreen)
                        }
                        .padding(10)
                        .background(GlucoTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(GlucoTheme.border, lineWidth: 1))
    }

    private var tandemSummaryStrip: some View {
        HStack(spacing: 10) {
            statPill(title: "24h Total Insulin", value: store.totalDailyInsulin, color: GlucoTheme.tandemCyan)
            statPill(title: "Active Carbs (COB)", value: "\(store.pumpStatus.cobGrams) g", color: GlucoTheme.highAmber)
            statPill(title: "Cartridge Left", value: "\(Int(store.pumpStatus.reservoirUnits)) U", color: GlucoTheme.inRangeGreen)
        }
    }

    private func statPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(GlucoTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GlucoTheme.border, lineWidth: 1))
    }

    private var eventsListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tandem t:slim X2 Event History")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GlucoTheme.textPrimary)

            if store.pumpEvents.isEmpty {
                Text("No pump events yet — waiting for live Tandem t:slim X2 BLE / Tandem Source sync or manual log.")
                    .font(.system(size: 12))
                    .foregroundStyle(GlucoTheme.textSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(GlucoTheme.border, lineWidth: 1))
            }

            ForEach(store.pumpEvents) { ev in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: ev.type.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GlucoTheme.tandemCyan)
                        .frame(width: 34, height: 34)
                        .background(GlucoTheme.cardElevated, in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ev.type.rawValue)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(GlucoTheme.textPrimary)
                            Spacer()
                            Text(Self.timeString(ev.timestamp))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(GlucoTheme.textSecondary)
                        }

                        HStack(spacing: 10) {
                            if let ins = ev.insulinUnits, ins > 0 {
                                Text(String(format: "%.2f U bolus", ins))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(GlucoTheme.tandemCyan)
                            }
                            if let c = ev.carbsGrams, c > 0 {
                                Text("\(c) g carbs")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(GlucoTheme.highAmber)
                            }
                            if let b = ev.basalRate {
                                Text(String(format: "%.2f U/hr basal", b))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(GlucoTheme.controlIQPurple)
                            }
                        }

                        if let note = ev.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(GlucoTheme.textSecondary)
                        }
                    }
                }
                .padding(14)
                .background(GlucoTheme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(GlucoTheme.border, lineWidth: 1))
            }
        }
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

struct QuickLogPumpSheet: View {
    @EnvironmentObject private var store: GlucoStore
    @Environment(\.dismiss) private var dismiss
    @State private var eventType: PumpEventType = .mealBolus
    @State private var insulinText: String = ""
    @State private var carbsText: String = ""
    @State private var iobText: String = ""
    @State private var reservoirText: String = ""
    @State private var batteryText: String = ""
    @State private var noteText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Safety Notice") {
                    Text("Read-only log entry: this records pump telemetry in GlucoPulse for monitoring only and never delivers insulin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Log Pump Event") {
                    Picker("Event Type", selection: $eventType) {
                        ForEach(PumpEventType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    TextField("Bolus Insulin (U), e.g. 3.2", text: $insulinText)
                        .keyboardType(.decimalPad)
                    TextField("Carbs (g), e.g. 45", text: $carbsText)
                        .keyboardType(.numberPad)
                    TextField("Note (optional)", text: $noteText)
                }

                Section("Update Current t:slim X2 Status (Optional)") {
                    TextField("Current IOB (U), e.g. \(String(format: "%.2f", store.pumpStatus.iobUnits))", text: $iobText)
                        .keyboardType(.decimalPad)
                    TextField("Cartridge Remaining (U), e.g. \(Int(store.pumpStatus.reservoirUnits))", text: $reservoirText)
                        .keyboardType(.numberPad)
                    TextField("Pump Battery (%), e.g. \(store.pumpStatus.batteryPercent)", text: $batteryText)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Record t:slim X2 Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let ins = Double(insulinText.replacingOccurrences(of: ",", with: "."))
                        let carbs = Int(carbsText)
                        if ins != nil || carbs != nil || !noteText.isEmpty {
                            store.logPumpEvent(type: eventType, insulin: ins, carbs: carbs, basal: nil, note: noteText)
                        }
                        if let newIOB = Double(iobText.replacingOccurrences(of: ",", with: ".")) {
                            store.pumpStatus.iobUnits = newIOB
                        }
                        if let newRes = Double(reservoirText) {
                            store.pumpStatus.reservoirUnits = newRes
                        }
                        if let newBatt = Int(batteryText) {
                            store.pumpStatus.batteryPercent = max(0, min(100, newBatt))
                        }
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

private struct SimpleWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct TandemPortalSheet: View {
    @Environment(\.dismiss) private var dismiss
    var initialURL: String = "https://source.tandemdiabetes.com"
    var title: String = "Tandem Source Portal"

    var body: some View {
        NavigationStack {
            SimpleWebView(url: URL(string: initialURL) ?? URL(string: "https://source.tandemdiabetes.com")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
