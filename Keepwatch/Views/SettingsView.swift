import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "binoculars.fill")
                            .font(.title)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keepwatch").font(.headline)
                            Text("Your NAS and media apps, at a glance. Keys are kept in the iPhone Keychain and only sent to your own servers.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.surface)

                ForEach(Service.allCases) { service in
                    ServiceSection(service: service)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                } footer: {
                    Text("Make sure Tailscale is on, on this iPhone, before testing a connection.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .keepwatchChrome()
        }
    }
}

private enum TestResult: Equatable {
    case running
    case success(String)
    case failure(String)
}

struct ServiceSection: View {
    let service: Service

    @EnvironmentObject private var settings: ServiceSettings
    @State private var test: TestResult?
    @State private var revealSecret = false

    private func binding<T>(_ keyPath: WritableKeyPath<ServiceConfig, T>) -> Binding<T> {
        Binding(
            get: { settings[service][keyPath: keyPath] },
            set: { newValue in
                var config = settings[service]
                config[keyPath: keyPath] = newValue
                settings.update(service, config)
                test = nil
            }
        )
    }

    var body: some View {
        Section {
            field("Address", text: binding(\.address), prompt: service.addressExample, keyboard: .URL)
            if service.usesLogin {
                field("Username", text: binding(\.username), prompt: "nzbget")
                secretField("Password", text: binding(\.password))
            } else {
                secretField("API key", text: binding(\.apiKey))
            }
            if service == .truenas {
                Toggle("Accept self-signed certificate", isOn: binding(\.acceptSelfSigned))
                if !settings[service].baseURL.isEmpty && !settings[service].isPrivateHost {
                    Toggle(isOn: binding(\.trustsDirectDomain)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This domain reaches TrueNAS directly")
                            Text("Only turn this on if it doesn't go through Cloudflare or a proxy. Otherwise TrueNAS will switch your key off.")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
            }
            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    switch test {
                    case .running: ProgressView()
                    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    case nil: EmptyView()
                    }
                }
            }
            .disabled(test == .running || settings[service].baseURL.isEmpty)
            if case .success(let message) = test {
                Text(message).font(.footnote).foregroundStyle(Theme.good)
            }
            if case .failure(let message) = test {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
            }
        } header: {
            Label(service.title, systemImage: service.symbol)
                .foregroundStyle(Theme.color(for: service))
        } footer: {
            Text(footer)
        }
        .listRowBackground(Theme.surface)
    }

    private var footer: String {
        switch service {
        case .truenas:
            return "Use https:// and your NAS's Tailscale IP, not your public (Cloudflare) web address. TrueNAS switches off an API key that reaches it over plain http, which Cloudflare does behind the scenes. Create a key in \(service.keyHelp)."
        case .nzbget:
            return "Find the username and password in \(service.keyHelp)."
        default:
            return "Copy the key from \(service.keyHelp). Find the port in TrueNAS → Apps → \(service.title)."
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func secretField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            Group {
                if revealSecret {
                    TextField(label, text: text, prompt: Text("Paste here"))
                } else {
                    SecureField(label, text: text, prompt: Text("Paste here"))
                }
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button {
                revealSecret.toggle()
            } label: {
                Image(systemName: revealSecret ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealSecret ? "Hide" : "Show")
        }
    }

    private func runTest() async {
        test = .running
        let config = settings[service]
        do {
            let message: String
            switch service {
            case .truenas:
                let client = try TrueNASClient(config: config)
                try await client.connect()
                message = "Connected: \([client.serverVersion, client.mode?.rawValue].compactMap { $0 }.joined(separator: " via "))"
                client.close()
            case .nzbget:
                let version = try await NZBGetClient(config: config).version()
                message = "Connected: NZBGet \(version)"
            case .sonarr, .radarr, .lidarr:
                let version = try await ArrClient(service: service, config: config).testConnection()
                message = "Connected: \(version)"
            }
            test = .success(message)
        } catch {
            test = .failure(describe(error))
        }
    }
}
