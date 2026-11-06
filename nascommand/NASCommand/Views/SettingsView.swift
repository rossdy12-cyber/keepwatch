import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: NASSettings
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://nas-server.co.uk", text: $settings.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Accept self-signed certificate", isOn: $settings.trustSelfSigned)
                } header: {
                    Text("TrueNAS address")
                } footer: {
                    Text("Your TrueNAS URL, or its Tailscale/LAN address, e.g. http://192.168.1.2 or http://100.x.x.x.")
                }

                Section {
                    SecureField("API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API key")
                } footer: {
                    Text("In TrueNAS: your username (top-right) \u{2192} API Keys \u{2192} Add. The key is stored in the iPhone Keychain and only sent to your NAS.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !settings.isConfigured)

                    if let result {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? Theme.good : Theme.danger)
                            .font(.footnote)
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
            let host = try await settings.client.test()
            result = (true, "Connected to \(host).")
        } catch {
            result = (false, describeError(error))
        }
        testing = false
    }
}
