import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offlineStore: OfflineStore

    @State private var notificationsEnabled = UserDefaults.standard.bool(forKey: "downloads.notificationsEnabled")

    var body: some View {
        NavigationStack {
            Form {
                Section("TrueNAS WebDAV") {
                    TextField(
                        "https://files.example.co.uk/webdav",
                        text: $settings.serverBaseURL
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField("Username", text: $settings.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $settings.password)
                }

                Section("Root folder") {
                    TextField("/Documents", text: $settings.rootPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Use a WebDAV path such as /Documents or /Media. Leave blank to start at the WebDAV root.")
                }

                Section("Offline files") {
                    LabeledContent(
                        "Storage used",
                        value: ByteCountFormatter.string(fromByteCount: offlineStore.storageUsage, countStyle: .file)
                    )

                    Toggle("Download notifications", isOn: $notificationsEnabled)
                }

                Section("Favourites") {
                    if settings.favouritePaths.isEmpty {
                        Text("No favourite folders yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.favouritePaths, id: \.self) { path in
                            Text(path)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: notificationsEnabled) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "downloads.notificationsEnabled")
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(OfflineStore())
}
