import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: GlucoStore
    @AppStorage("glucopulse.bolus.maxSingleUnits") private var bolusMaxSingleUnits = 10.0
    @AppStorage("glucopulse.bolus.maxIOBUnits") private var bolusMaxIOBUnits = 15.0
    @AppStorage("glucopulse.bolus.minimumGlucoseMmolL") private var bolusMinimumGlucose = 4.0
    @State private var syncFeedback: String?
    @State private var showingTrueNASPortal = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Units & Target Range") {
                    Picker("Glucose Units", selection: $store.unit) {
                        ForEach(GlucoseUnit.allCases) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }

                    HStack {
                        Text("Low Threshold")
                        Spacer()
                        Text("\(store.formatGlucose(store.lowMgdL)) \(store.unit.rawValue)")
                            .foregroundStyle(GlucoTheme.lowRed)
                            .fontWeight(.bold)
                        Stepper("", value: $store.lowMgdL, in: 55...100, step: 5)
                            .labelsHidden()
                    }

                    HStack {
                        Text("High Threshold")
                        Spacer()
                        Text("\(store.formatGlucose(store.highMgdL)) \(store.unit.rawValue)")
                            .foregroundStyle(GlucoTheme.highAmber)
                            .fontWeight(.bold)
                        Stepper("", value: $store.highMgdL, in: 140...270, step: 4)
                            .labelsHidden()
                    }

                    Toggle("Glucose Push Notifications", isOn: $store.alertsEnabled)
                    Toggle("High Glucose Alerts", isOn: $store.highAlertsEnabled)
                        .disabled(!store.alertsEnabled)

                    Picker("High Alert Repeat", selection: $store.highAlertRepeatMinutes) {
                        Text("Once per High (No Repeat)").tag(0)
                        Text("Every 30 Minutes").tag(30)
                        Text("Every 60 Minutes").tag(60)
                        Text("Every 2 Hours").tag(120)
                    }
                    .disabled(!store.alertsEnabled || !store.highAlertsEnabled)

                    Button {
                        if store.isAlertSnoozed {
                            store.clearAlertSnooze()
                        } else {
                            store.snoozeAlerts(minutes: 60)
                        }
                    } label: {
                        Label(
                            store.isAlertSnoozed ? "Alerts Muted (Tap to Resume)" : "Snooze All Glucose Alerts for 1 Hour",
                            systemImage: store.isAlertSnoozed ? "bell.slash.fill" : "bell.badge.slash"
                        )
                        .foregroundStyle(store.isAlertSnoozed ? GlucoTheme.highAmber : GlucoTheme.tandemCyan)
                    }
                }

                Section {
                    HStack {
                        Text("Maximum Single Bolus")
                        Spacer()
                        Text(String(format: "%.1f U", bolusMaxSingleUnits))
                            .fontWeight(.bold)
                        Stepper("", value: $bolusMaxSingleUnits, in: 1...30, step: 0.5)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Maximum Dose + IOB")
                        Spacer()
                        Text(String(format: "%.1f U", bolusMaxIOBUnits))
                            .fontWeight(.bold)
                        Stepper("", value: $bolusMaxIOBUnits, in: 1...40, step: 0.5)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Minimum Glucose")
                        Spacer()
                        Text(String(format: "%.1f mmol/L", bolusMinimumGlucose))
                            .fontWeight(.bold)
                        Stepper("", value: $bolusMinimumGlucose, in: 3...8, step: 0.1)
                            .labelsHidden()
                    }
                } header: {
                    Text("Bolus Safety Limits")
                } footer: {
                    Text("These limits apply to bolus plans created in GlucoPulse. They do not override the safety checks or confirmation requirements on your Tandem t:slim X2.")
                }

                Section {
                    Toggle("Direct Dexcom G7 Bluetooth LE", isOn: $store.g7DirectBLEEnabled)
                    HStack {
                        Text("4-Digit G7 Pairing Code")
                        Spacer()
                        TextField("e.g. 1234", text: $store.g7PairingCode)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .fontWeight(.bold)
                            .foregroundStyle(GlucoTheme.inRangeGreen)
                            .frame(width: 110)
                    }
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(GlucoTheme.inRangeGreen)
                        Text(store.g7BLEStatus)
                            .font(.caption)
                            .foregroundStyle(GlucoTheme.textSecondary)
                    }
                    Button {
                        store.startDirectG7BLE()
                        store.pollConnectedG7Peripherals()
                        syncFeedback = store.g7BLEStatus
                    } label: {
                        Label("Pair & Connect Dexcom G7 (\(store.g7BLEConnectedName.isEmpty ? "DXCMAK" : store.g7BLEConnectedName))", systemImage: "wave.3.right.circle.fill")
                            .foregroundStyle(GlucoTheme.inRangeGreen)
                    }
                } header: {
                    Text("Standalone Mode 1 · Direct Dexcom G7 Bluetooth LE")
                } footer: {
                    Text("To pair without the official Dexcom app installed, enter your active sensor's 4-digit Pairing Code (shown on your Tandem t:slim X2 pump under Options → My CGM → Pairing Code, or on the G7 applicator). Performs full standalone J-PAKE + AES-128 auth on Slot 2.")
                }

                Section {
                    Picker("Tandem Region", selection: $store.tandemRegion) {
                        Text("UK / Europe / International (EU)").tag("EU")
                        Text("United States (US)").tag("US")
                    }
                    TextField("Tandem Source Email", text: $store.tandemEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Tandem Source Password", text: $store.tandemPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("t:slim X2 Serial Number (optional)", text: $store.tandemPumpSerial)
                        .keyboardType(.numberPad)

                    Button {
                        syncFeedback = "Searching for Tandem t:slim X2…"
                        store.submitTandemPairingCode()

                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            syncFeedback = store.tandemDiagnostic.isEmpty
                                ? store.tandemBLEStatus
                                : store.tandemDiagnostic
                        }
                    } label: {
                        HStack {
                            Label("Pair Tandem t:slim X2", systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if store.tandemConnected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GlucoTheme.inRangeGreen)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "gluco.savedTandemUUID.v5")
                        UserDefaults.standard.removeObject(forKey: "gluco.tandemPairingCode")

                        store.tandemPairingCode = ""
                        store.tandemConnected = false
                        store.tandemNeedsPairingCode = true
                        store.tandemDiagnostic = "Old Tandem pump profile forgotten. Force-close and reopen GlucoPulse, then pair again with a new pump pairing code."
                        store.tandemBLEStatus = "Saved Tandem pump profile cleared. Restart GlucoPulse, then pair again."

                        syncFeedback = store.tandemDiagnostic
                    } label: {
                        Label("Forget Tandem Pump Profile", systemImage: "trash")
                            .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GlucoTheme.textSecondary)
                        Text(store.tandemBLEStatus)
                            .font(.caption)
                            .foregroundStyle(GlucoTheme.tandemCyan)
                        Text(store.tandemDiagnostic.isEmpty ? "No diagnostic message yet." : store.tandemDiagnostic)
                            .font(.caption)
                            .foregroundStyle(store.tandemDiagnostic.isEmpty ? GlucoTheme.textSecondary : GlucoTheme.highAmber)
                    }
                } header: {
                    Text("Standalone Mode 2 · Tandem Source (G7 CGM + t:slim X2)")
                } footer: {
                    Text("For direct Bluetooth pairing, enable Mobile Connection on the pump under Options → Device Settings → Bluetooth Settings, keep the pump on its pairing screen, and ensure GlucoPulse has Bluetooth permission. Tandem Source sync is separate and supplies historical pump/CGM data through TrueNAS.")
                }

                Section {
                    TextField("Nightscout or TrueNAS Bridge URL", text: $store.nightscoutURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Secret / Read Token (optional)", text: $store.nightscoutToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            let ok = await store.syncNightscout()
                            store.tandemConnected = ok
                            if ok { store.demoMode = false }
                            syncFeedback = ok
                                ? "Connected to TrueNAS Nightscout (:1337)"
                                : "Connected to Nightscout (0 entries yet — enter Tandem Source login above or wait for G7 BLE)."
                        }
                    } label: {
                        Label("Refresh TrueNAS Nightscout (:1337)", systemImage: "drop.transmission")
                            .foregroundStyle(GlucoTheme.tandemCyan)
                    }

                    Button {
                        showingTrueNASPortal = true
                    } label: {
                        Label("Open TrueNAS Bridge Web UI (:1338)", systemImage: "server.rack")
                            .foregroundStyle(GlucoTheme.tandemCyan)
                    }
                } header: {
                    Text("TrueNAS Nightscout Bridge (:1337 / :1338)")
                }
                .sheet(isPresented: $showingTrueNASPortal) {
                    TandemPortalSheet(initialURL: store.truenasBridgeBaseURL, title: "TrueNAS tconnectsync Bridge")
                }

                Section {
                    Picker("Dexcom Server Region", selection: $store.dexcomRegion) {
                        ForEach(DexcomRegion.allCases) { reg in
                            Text(reg.rawValue).tag(reg)
                        }
                    }
                    TextField("Dexcom Username / Email / Phone", text: $store.dexcomUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Dexcom Password", text: $store.dexcomPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            let ok = await store.syncDexcomShare()
                            store.dexcomConnected = ok
                            if ok && !store.readings.isEmpty { store.demoMode = false }
                            syncFeedback = store.dexcomDiagnostic
                        }
                    } label: {
                        Label("Verify Dexcom Share Account (Optional)", systemImage: "sensor.tag.radiowaves.forward.fill")
                            .foregroundStyle(GlucoTheme.inRangeGreen)
                    }
                } header: {
                    Text("Optional · Dexcom Share Cloud")
                } footer: {
                    Text("Only used if you also run the official Dexcom app. Not required when using Direct G7 Bluetooth LE or Tandem Source CGM above.")
                }

                if let feedback = syncFeedback {
                    Section("Sync Status") {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(GlucoTheme.tandemCyan)
                    }
                }

                Section("Telemetry Mode") {
                    Toggle("Demo / Simulation Mode", isOn: $store.demoMode)
                }
            }
            .navigationTitle("Sources & Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}