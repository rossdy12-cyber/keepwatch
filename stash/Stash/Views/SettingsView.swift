import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: StashStore
    @State private var feedbackMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection Status") {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(store.isOnline ? StashTheme.success : StashTheme.warning)
                            .frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.isOnline ? "Stash Server Online" : "Stash Server Unreachable")
                                .font(.subheadline.weight(.semibold))
                            Text(store.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Test") {
                            Task { await store.refreshAll() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StashTheme.accent)
                    }
                }

                Section("TrueNAS Stash Server") {
                    ForEach(StashStore.presets, id: \.url) { preset in
                        Button {
                            store.serverAddress = preset.url
                            Task { await store.refreshAll() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(preset.url) — \(preset.subtitle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.serverAddress == preset.url {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(StashTheme.accent)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom Server Address")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("http://100.85.127.42:9999", text: $store.serverAddress)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key (optional, if Stash login is enabled)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Paste Stash API key…", text: $store.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("TrueNAS Storage Mount (/data/IDrive-Sync)") {
                    Button {
                        Task {
                            feedbackMessage = await store.triggerScan()
                            await store.refreshAll()
                        }
                    } label: {
                        Label("Scan /data/IDrive-Sync Library", systemImage: "folder.badge.gearshape")
                    }

                    Button {
                        Task {
                            feedbackMessage = await store.triggerGenerate()
                        }
                    } label: {
                        Label("Generate Covers, Previews & Sprites", systemImage: "wand.and.stars")
                    }

                    if let msg = feedbackMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(StashTheme.accent)
                    }
                }

                Section("Privacy & Security") {
                    Toggle("Require Face ID / Passcode", isOn: $store.biometricLock)
                    Toggle("Blur Screen in iOS App Switcher", isOn: $store.privacyBlur)
                    Toggle("Accept Self-Signed HTTPS Certificates", isOn: $store.acceptSelfSigned)

                    Button(role: .destructive) {
                        WKWebsiteDataStore.default().removeData(
                            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                            modifiedSince: .distantPast
                        ) {
                            feedbackMessage = "Cleared WebView cache & cookies"
                        }
                    } label: {
                        Label("Clear Web Cache & Cookies", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
