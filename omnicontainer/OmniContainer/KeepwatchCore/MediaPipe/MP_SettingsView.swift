import SwiftUI

struct MPSettingsView: View {
    @EnvironmentObject private var settings: MPAppSettings

    @State private var isTestingConnection = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("MeTube server") {
                    TextField(
                        "https://metube.example.co.uk",
                        text: $settings.serverBaseURL
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    SecureField("API token (optional)", text: $settings.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Default destination") {
                    TextField("Media/YouTube", text: $settings.defaultFolder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTestingConnection {
                            ProgressView()
                        } else {
                            Label("Test MeTube connection", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .disabled(!settings.isConfigured || isTestingConnection)
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
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        isError = false
        statusMessage = nil

        do {
            let client = MPMeTubeClient(settings: settings)
            let formats = try await client.fetchFormats()
            statusMessage = "Connected. \(formats.count) formats available."
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }

        isTestingConnection = false
    }
}

#Preview {
    MPSettingsView()
        .environmentObject(MPAppSettings())
}
