import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore

    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://jarvis.nas-server.co.uk", text: $settings.config.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Accept self-signed certificate", isOn: $settings.config.trustSelfSigned)
                } header: {
                    Text("Jarvis core")
                } footer: {
                    Text("Your Jarvis domain, or the NAS's Tailscale address and port, for example http://100.x.x.x:8000.")
                }

                Section {
                    Picker("Connection type", selection: $settings.config.style) {
                        ForEach(APIStyle.allCases) { Text($0.label).tag($0) }
                    }
                    if let detection = settings.detection, settings.config.style == .auto {
                        Label(detection.summary, systemImage: "sparkle.magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    let endpoint = settings.endpoint
                    if endpoint.style == .openAI || endpoint.style == .ollama {
                        modelField
                    }
                    if settings.config.style == .custom || (settings.config.style == .auto && endpoint.style == .custom) {
                        LabeledContent("Chat path") {
                            TextField("/api/chat", text: $settings.config.chatPath)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        LabeledContent("Message field") {
                            TextField("message", text: $settings.config.messageField)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    LabeledContent("Health path") {
                        TextField("/health", text: $settings.config.healthPath)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("API")
                } footer: {
                    Text(apiFooter)
                }

                Section {
                    SecureField("Access token (optional)", text: $settings.secrets.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Cloudflare Access client ID", text: $settings.secrets.cfClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Cloudflare Access client secret", text: $settings.secrets.cfClientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Security")
                } footer: {
                    Text("The token is sent as \"Authorization: Bearer …\". Fill in the Cloudflare Access fields only if the domain is protected by Cloudflare Zero Trust. All of these are kept in the iPhone Keychain.")
                }

                Section {
                    Picker("Speak replies", selection: $settings.config.speakMode) {
                        ForEach(SpeakMode.allCases) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions for Jarvis")
                            .font(.subheadline)
                        TextField("e.g. Keep answers short and call me sir.", text: $settings.config.systemPrompt, axis: .vertical)
                            .lineLimit(2...6)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("Instructions are sent as a system message to OpenAI-compatible and Ollama servers.")
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
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(testResult.ok ? Theme.good : Theme.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private var modelField: some View {
        let models = settings.detection?.models ?? []
        if models.isEmpty {
            LabeledContent("Model") {
                TextField("model name", text: $settings.config.model)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } else {
            Picker("Model", selection: $settings.config.model) {
                Text("Default (\(models[0]))").tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var apiFooter: String {
        switch settings.endpoint.style {
        case .openAI, .auto:
            return "Chats go to POST /v1/chat/completions, streamed."
        case .ollama:
            return "Chats go to POST /api/chat, streamed."
        case .custom:
            let endpoint = settings.endpoint
            return "Chats go to POST \(endpoint.chatPath) as {\"\(endpoint.messageField)\": \"…\", \"session_id\": \"…\"}. The reply can be plain text, JSON (reply, response, answer, text, content or message), or streamed."
        }
    }

    private func test() async {
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
