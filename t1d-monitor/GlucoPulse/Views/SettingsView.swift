import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: GlucoStore
    @State private var syncFeedback: String?

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
                            if ok { store.demoMode = false }
                            syncFeedback = ok
                                ? "Connected to Dexcom Share (\(store.readings.count) readings loaded)"
                                : "Dexcom login failed — verify Share is enabled in the G7 app and check region/credentials."
                        }
                    } label: {
                        HStack {
                            Label("Connect & Sync Dexcom G7 Share", systemImage: "sensor.tag.radiowaves.forward.fill")
                            Spacer()
                            if store.dexcomConnected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GlucoTheme.inRangeGreen)
                            }
                        }
                    }
                } header: {
                    Text("Dexcom G7 (Direct Share Cloud)")
                } footer: {
                    Text("Uses your Dexcom G7 Share account directly. Use 'UK / International (shareous1)' for UK/EU accounts.")
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
                                ? "Connected to Nightscout / Tandem Bridge"
                                : "Couldn't reach Nightscout URL."
                        }
                    } label: {
                        HStack {
                            Label("Sync Tandem / Nightscout Server", systemImage: "drop.transmission")
                            Spacer()
                            if store.tandemConnected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GlucoTheme.tandemCyan)
                            }
                        }
                    }
                } header: {
                    Text("Tandem t:slim X2 / Nightscout Bridge")
                } footer: {
                    Text("Pulls Tandem t:slim X2 IOB, Control-IQ basal modulation, boluses, reservoir units, and pump battery from Nightscout / tconnectsync.")
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
