import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: GlucoStore
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
                        Stepper("", value: $store.highMgdL, in: 140...250, step: 5)
                            .labelsHidden()
                    }
                }

                Section {
                    Toggle("Direct Dexcom G7 Bluetooth LE", isOn: $store.g7DirectBLEEnabled)
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
                        Label("Scan & Attach Bonded Dexcom G7 Sensor", systemImage: "wave.3.right.circle.fill")
                            .foregroundStyle(GlucoTheme.inRangeGreen)
                    }
                } header: {
                    Text("Standalone Mode 1 · Direct Dexcom G7 Bluetooth LE")
                } footer: {
                    Text("Reads glucose (0x4e) & 6h backfill (0x59) directly from your nearby Dexcom G7 over iOS CoreBluetooth GATT (FEBC / F8083532) without needing the official Dexcom G7 app.")
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
                        Task {
                            let ok = await store.saveAndSyncTandemSource()
                            syncFeedback = store.tandemDiagnostic.isEmpty
                                ? (ok ? "Synced Tandem Source (G7 CGM + Pump)!" : "Tandem Source sync failed.")
                                : store.tandemDiagnostic
                        }
                    } label: {
                        HStack {
                            Label("Save & Sync Tandem Source (G7 CGM + Pump)", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            Spacer()
                            if store.tandemConnected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GlucoTheme.tandemCyan)
                            }
                        }
                    }
                } header: {
                    Text("Standalone Mode 2 · Tandem Source (G7 CGM + t:slim X2)")
                } footer: {
                    Text("Your Tandem t:slim X2 pump uploads every 5-minute Dexcom G7 reading plus IOB, basal & boluses to Tandem Source. Saving here configures TrueNAS tconnectsync (:1338) with CGM enabled — no Dexcom app needed.")
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
                        HStack {
                            Label("Refresh TrueNAS Nightscout (:1337)", systemImage: "drop.transmission")
                            Spacer()
                            if store.tandemConnected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GlucoTheme.tandemCyan)
                            }
                        }
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
                        HStack {
                            Label("Verify Dexcom Share Account (Optional)", systemImage: "sensor.tag.radiowaves.forward.fill")
                            Spacer()
                            if store.dexcomConnected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GlucoTheme.inRangeGreen)
                            }
                        }
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
