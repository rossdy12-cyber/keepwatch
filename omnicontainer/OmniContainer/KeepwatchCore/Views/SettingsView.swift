import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var jarvisSettings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var paydays: PaydaysStore
    @EnvironmentObject private var portal: PortalStore
    @EnvironmentObject private var hub: HubStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.title)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keepwatch Super-App").font(.headline)
                            Text("TrueNAS Pulse, NAS Portal + 2FA, Jarvis AI & Navidrome, Paydays Budget, Gothic Hub & Store Admin in one app.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.surface)

                // 1. Paydays Budget Section
                PaydaysSettingsSection()

                // 2. Jarvis Core, Voice & Music Sections
                JarvisSettingsSections()

                // 3. TrueNAS & Arr Services
                ForEach(Service.allCases) { service in
                    ServiceSection(service: service)
                }

                // 4. NAS Portal & Two-Factor Codes
                OTPSection()
                    .listRowBackground(Theme.surface)

                PortalExtraSection()

                // 5. WooCommerce Store Admin
                StoreSettingsSection()

                // 6. Hidden Folders in Files
                HiddenFoldersSection()

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")
                } footer: {
                    Text("All keys, passwords and 2FA secrets are stored solely in this iPhone's Keychain.")
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

// MARK: - Paydays Settings Section

struct PaydaysSettingsSection: View {
    @EnvironmentObject private var paydays: PaydaysStore
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Section {
            TextField("http://100.85.127.42:8450", text: $paydays.config.address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("App password (optional)", text: $paydays.config.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Apple Pay hook link or token (optional)", text: $paydays.config.hookURLOrToken)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Accept self-signed certificate", isOn: $paydays.config.acceptSelfSigned)
            Button {
                Task {
                    testing = true
                    result = nil
                    await paydays.refresh()
                    testing = false
                    if let err = paydays.errorMessage {
                        result = (false, err)
                    } else {
                        result = (true, "Connected to Paydays. " + paydays.statusLine())
                    }
                }
            } label: {
                HStack {
                    Text("Test Paydays connection")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || !paydays.config.isConfigured)
            if let result {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(result.ok ? Theme.good : Theme.danger)
            }
        } header: {
            Label("Paydays Budget", systemImage: "sterlingsign.circle")
                .foregroundStyle(Theme.paydaysGreen)
        } footer: {
            Text("Use http://<nas-tailscale-ip>:8450 or https://paydays.nas-server.co.uk. Paste the /hook/spend?token=… link if Paydays sits behind Authelia so Siri and the Action Button can log spending directly.")
        }
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Jarvis, Voice & Navidrome Settings

struct JarvisSettingsSections: View {
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var speaker: Speaker

    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testingMusic = false
    @State private var musicResult: (ok: Bool, message: String)?

    var body: some View {
        Section {
            TextField("https://jarvis.nas-server.co.uk", text: $settings.config.address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Accept self-signed certificate", isOn: $settings.config.trustSelfSigned)
            Picker("Connection type", selection: $settings.config.style) {
                ForEach(APIStyle.allCases) { Text($0.label).tag($0) }
            }
            if let detection = settings.detection, settings.config.style == .auto {
                Label(detection.summary, systemImage: "sparkle.magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            SecureField("Bearer token (optional)", text: $settings.secrets.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Cloudflare Access client ID (optional)", text: $settings.secrets.cfClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Cloudflare Access secret (optional)", text: $settings.secrets.cfClientSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Speak replies", selection: $settings.config.speakMode) {
                ForEach(SpeakMode.allCases) { Text($0.label).tag($0) }
            }
            Button {
                Task { await testJarvis() }
            } label: {
                HStack {
                    Text("Test Jarvis connection")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || !settings.isConfigured)
            if let testResult {
                Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(testResult.ok ? Theme.good : Theme.danger)
            }
        } header: {
            Label("Jarvis AI Core", systemImage: "waveform.circle")
                .foregroundStyle(Theme.jarvisBlue)
        } footer: {
            Text("Your Jarvis domain (https://jarvis.nas-server.co.uk) or Tailscale address and port.")
        }
        .listRowBackground(Theme.surface)

        Section {
            Picker("Voice", selection: $settings.voice.mode) {
                ForEach(VoiceSettings.Mode.allCases) { Text($0.label).tag($0) }
            }
            if settings.voice.mode != .iphone {
                TextField("http://100.85.127.42:10701", text: $settings.voice.hubAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Voice hub key", text: $settings.voice.hubKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if settings.voice.mode != .hub {
                Picker("iPhone voice", selection: $settings.voice.iphoneVoiceID) {
                    Text("Best British voice").tag(String?.none)
                    ForEach(VoiceSettings.englishVoices(), id: \.identifier) { voice in
                        Text(VoiceSettings.label(voice)).tag(String?.some(voice.identifier))
                    }
                }
            }
            Button {
                speaker.speak("Good evening, sir. All systems are online, and the storage pool is in excellent health.")
            } label: {
                Label("Preview Jarvis voice", systemImage: "speaker.wave.2")
            }
        } header: {
            Label("Jarvis Voice (Kokoro / iPhone)", systemImage: "speaker.wave.3")
                .foregroundStyle(Theme.jarvisBlue)
        }
        .listRowBackground(Theme.surface)

        Section {
            TextField("https://navidrome.nas-server.co.uk", text: $settings.navidrome.address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $settings.navidrome.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $settings.navidrome.password)
            Picker("Quality", selection: $settings.navidrome.maxBitRate) {
                Text("Original (lossless)").tag(Int?.none)
                ForEach([320, 256, 192, 128], id: \.self) { Text("\($0) kbps MP3").tag(Int?.some($0)) }
            }
            Button {
                Task { await testMusic() }
            } label: {
                HStack {
                    Text("Test Navidrome")
                    Spacer()
                    if testingMusic { ProgressView() }
                }
            }
            .disabled(testingMusic || !settings.navidrome.isConfigured)
            if let musicResult {
                Label(musicResult.message, systemImage: musicResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(musicResult.ok ? Theme.good : Theme.danger)
            }
        } header: {
            Label("Music (Navidrome)", systemImage: "music.note")
                .foregroundStyle(Theme.jarvisBlue)
        }
        .listRowBackground(Theme.surface)
    }

    private func testMusic() async {
        testingMusic = true
        musicResult = nil
        defer { testingMusic = false }
        do {
            try await NavidromeClient(account: settings.navidrome).ping()
            musicResult = (true, "Connected to Navidrome.")
        } catch let error as MusicError {
            musicResult = (false, error.localizedDescription)
        } catch {
            musicResult = (false, describe(error))
        }
    }

    private func testJarvis() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let client = settings.client
        let health = await client.health(path: settings.config.healthPath)
        chat.health = health
        if case .offline(let message) = health {
            testResult = (false, message)
            return
        }
        do {
            let detection = try await client.detect()
            settings.detection = detection
            testResult = (true, "Connected. " + detection.summary)
        } catch {
            testResult = (false, describe(error))
        }
    }
}

// MARK: - Portal & Vaultwarden 2FA Transfer Section

struct PortalExtraSection: View {
    @EnvironmentObject private var portal: PortalStore
    @State private var confirmSignOut = false
    @State private var signedOut = false

    var body: some View {
        Section {
            Toggle("Accept self-signed certs in Portal WebView", isOn: $portal.acceptSelfSigned)
            NavigationLink {
                TransferView()
            } label: {
                Label("Move 2FA codes to Vaultwarden", systemImage: "arrow.right.doc.on.clipboard")
            }
            Button("Sign out of Portal web sessions", role: .destructive) {
                confirmSignOut = true
            }
            if signedOut {
                Label("Signed out of web sessions.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Label("NAS Portal Browser", systemImage: "globe")
                .foregroundStyle(Theme.accent)
        }
        .listRowBackground(Theme.surface)
        .confirmationDialog("Sign out of TrueNAS, Authelia and every web app?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                        modifiedSince: .distantPast) {
                    signedOut = true
                }
            }
        }
    }
}

// MARK: - WooCommerce Store Section

struct StoreSettingsSection: View {
    @EnvironmentObject private var hub: HubStore

    var body: some View {
        Section {
            TextField("https://your-store.co.uk", text: $hub.wooConfig.siteURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Consumer Key (ck_…)", text: $hub.wooConfig.consumerKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Consumer Secret (cs_…)", text: $hub.wooConfig.consumerSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Label("WooCommerce Store Admin", systemImage: "bag.fill")
                .foregroundStyle(Theme.gothicPurple)
        } footer: {
            Text("Create a Read/Write REST API key in WordPress → WooCommerce → Settings → Advanced → REST API.")
        }
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Existing Keepwatch Service & Hidden Folders Sections

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

struct HiddenFoldersSection: View {
    @AppStorage(HiddenPaths.storageKey) private var hiddenText = ""

    var body: some View {
        let paths = HiddenPaths.decode(hiddenText)
        Section {
            if paths.isEmpty {
                Text("Nothing hidden. In Files, swipe left on a folder (or press and hold it) to hide it.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(paths, id: \.self) { path in
                HStack {
                    Text(path)
                        .font(.subheadline)
                        .lineLimit(2)
                        .truncationMode(.head)
                    Spacer()
                    Button("Show") {
                        hiddenText = HiddenPaths.toggled(path, in: hiddenText)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Label("Hidden in Files", systemImage: "eye.slash")
        } footer: {
            Text("Hiding only affects this app. Nothing on the NAS is changed.")
        }
        .listRowBackground(Theme.surface)
    }
}
