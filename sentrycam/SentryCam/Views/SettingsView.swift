import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: FrigateSettings
    @EnvironmentObject private var store: FrigateStore
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://100.85.127.42:8971", text: $settings.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Accept self-signed certificate", isOn: $settings.trustSelfSigned)
                } header: {
                    Text("Frigate address")
                } footer: {
                    Text("Your Frigate URL. The authenticated port (\u{2236}8971) uses a self-signed certificate, so leave the toggle on for it.")
                }

                Section {
                    TextField("Username", text: $settings.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $settings.password)
                } header: {
                    Text("Login")
                } footer: {
                    Text("A Frigate login (Settings \u{2192} Users; a viewer account is enough). Leave blank if your Frigate port has no authentication.")
                }

                Section {
                    TextField("http://100.85.127.42:9092", text: $settings.agentURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Tapo patrol agent (optional)")
                } footer: {
                    Text("Your NAS agent that runs the PTZ patrol container. Leave blank to hide the patrol controls.")
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
                            .foregroundStyle(result.ok ? Theme.good : Theme.accent).font(.footnote)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func test() async {
        testing = true
        result = nil
        do {
            let client = settings.client
            if settings.needsLogin { try await client.login() }
            let cams = try await client.cameras()
            result = (true, cams.isEmpty ? "Connected, but no cameras found." : "Connected. \(cams.count) camera\(cams.count == 1 ? "" : "s"): \(cams.map { $0.prettyCamera }.joined(separator: ", ")).")
            await store.start(settings)
        } catch {
            result = (false, describeError(error))
        }
        testing = false
    }
}
