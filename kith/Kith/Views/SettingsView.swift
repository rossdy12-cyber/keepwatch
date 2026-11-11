import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: KithSettings
    @EnvironmentObject private var store: CompanionStore
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $store.userName)
                    .textContentType(.givenName)
            } header: {
                Text("You")
            } footer: {
                Text("Your companions use this to address you (optional).")
            }

            Section {
                TextField("https://jarvis.nas-server.co.uk", text: $settings.coreURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Access token (optional)", text: $settings.token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Accept self-signed certificate", isOn: $settings.trustSelfSigned)
            } header: {
                Text("Jarvis core")
            } footer: {
                Text("Your companions think using your jarvis-core. Each one gets its own personality and memory.")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack { Text("Test connection"); Spacer(); if testing { ProgressView() } }
                }
                .disabled(testing || !settings.isConfigured)
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red).font(.footnote)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func test() async {
        testing = true; result = nil
        let ok = await settings.client.ping()
        result = ok ? (true, "Connected to your core.") : (false, "Couldn't reach the core — check the address.")
        testing = false
    }
}
