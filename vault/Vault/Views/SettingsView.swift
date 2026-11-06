import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vault: VaultModel

    @State private var serverURL = ""
    @State private var webDAVPath = "/"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("TrueNAS WebDAV") {
                TextField("Server URL", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("WebDAV path", text: $webDAVPath)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Account") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("WebDAV password", text: $password)
            }

            Section {
                Button("Save and test connection") {
                    vault.settings.serverURL = serverURL
                    vault.settings.webDAVPath = webDAVPath
                    vault.settings.username = username
                    vault.settings.password = password

                    vault.saveSettings()

                    Task {
                        await vault.testConnection()
                    }
                }

                if let message = vault.connectionMessage {
                    Text(message)
                        .foregroundStyle(message.contains("success") ? .green : .red)
                }
            }

            Section("How it works") {
                Text("Vault connects directly to your private WebDAV endpoint on TrueNAS. Your password is stored in the iOS Keychain and is never included in the app build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            serverURL = vault.settings.serverURL
            webDAVPath = vault.settings.webDAVPath
            username = vault.settings.username
            password = vault.settings.password
        }
    }
}
