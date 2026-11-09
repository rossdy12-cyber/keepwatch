import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var wifiOnly = UploadPreferences().wifiOnly
    @State private var notificationsEnabled = UploadPreferences().notificationsEnabled
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("TrueNAS WebDAV") {
                    TextField(
                        "https://documents.example.co.uk/webdav",
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

                Section {
                    TextField("Documents", text: $settings.remoteFolder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Remote folder")
                } footer: {
                    Text("Uploads are placed in <remote folder>/<year>/<month>/<day>/<filename>.pdf.")
                }

                Section {
                    Toggle("Wi-Fi only", isOn: $wifiOnly)
                    Toggle("Upload notifications", isOn: $notificationsEnabled)
                } header: {
                    Text("Uploads")
                } footer: {
                    Text("Wi-Fi only prevents uploads over cellular data. Notifications report completed and failed uploads.")
                }

                if let statusMessage {
                    Section {
                        Label(
                            statusMessage,
                            systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: wifiOnly) { _, newValue in
                UploadPreferences().wifiOnly = newValue
            }
            .onChange(of: notificationsEnabled) { _, newValue in
                UploadPreferences().notificationsEnabled = newValue

                if newValue {
                    Task {
                        try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge])
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
}
