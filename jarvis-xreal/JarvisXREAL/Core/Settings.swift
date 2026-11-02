import Foundation

/// How the app talks to the Jarvis core.
enum APIStyle: String, CaseIterable, Codable, Identifiable {
    /// Look at the server once and pick one of the others.
    case auto
    /// `POST /v1/chat/completions` (OpenAI, LocalAI, LiteLLM, Open WebUI, vLLM, LM Studio…).
    case openAI
    /// `POST /api/chat` with newline-delimited JSON (Ollama).
    case ollama
    /// Any JSON endpoint: `POST <path>` with `{"<field>": "<your message>", "session_id": "…"}`.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Detect automatically"
        case .openAI: return "OpenAI-compatible"
        case .ollama: return "Ollama"
        case .custom: return "Custom JSON endpoint"
        }
    }
}

enum SpeakMode: String, CaseIterable, Codable, Identifiable {
    case never, afterVoice, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .afterVoice: return "When I spoke"
        case .always: return "Always"
        }
    }
}

struct JarvisConfig: Codable, Equatable {
    var address = "https://jarvis.nas-server.co.uk"
    var style: APIStyle = .auto
    /// Model name for OpenAI-compatible and Ollama servers. Empty = the first one the server lists.
    var model = ""
    /// Custom endpoint only.
    var chatPath = "/api/chat"
    var messageField = "message"
    var healthPath = "/health"
    var systemPrompt = ""
    var trustSelfSigned = false
    var speakMode: SpeakMode = .afterVoice
}

struct JarvisSecrets: Codable, Equatable {
    /// Sent as `Authorization: Bearer <token>`.
    var token = ""
    /// Cloudflare Access service token, for when the domain sits behind Cloudflare Access (Zero Trust).
    var cfClientID = ""
    var cfClientSecret = ""
}

/// What auto-detection found on the server.
struct Detection: Codable, Equatable {
    var style: APIStyle
    var models: [String] = []
    var chatPath: String?
    var messageField: String?
    var summary: String
}

/// The concrete endpoint a chat request goes to, after auto-detection has been applied.
struct ResolvedEndpoint {
    var style: APIStyle
    var model: String
    var chatPath: String
    var messageField: String
}

@MainActor
final class JarvisSettings: ObservableObject {
    /// One copy for the app and for Siri requests.
    static let shared = JarvisSettings()

    private static let configKey = "jarvis.config"
    private static let detectionKey = "jarvis.detection"
    private static let secretsKey = "secrets"

    @Published var config: JarvisConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Self.configKey)
            }
            if oldValue.address != config.address || oldValue.style != config.style {
                detection = nil
            }
            applyTrust(old: oldValue)
        }
    }

    @Published var secrets: JarvisSecrets {
        didSet { Keychain.save(secrets, for: Self.secretsKey) }
    }

    /// Which voice Jarvis speaks with (and the voice hub's key), kept in the Keychain.
    @Published var voice: VoiceSettings {
        didSet { Keychain.save(voice, for: "voice") }
    }

    /// Navidrome sign-in for playing music, kept in the Keychain.
    @Published var navidrome: NavidromeAccount {
        didSet { Keychain.save(navidrome, for: "navidrome") }
    }

    @Published var detection: Detection? {
        didSet {
            if let detection, let data = try? JSONEncoder().encode(detection) {
                UserDefaults.standard.set(data, forKey: Self.detectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.detectionKey)
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        config = defaults.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(JarvisConfig.self, from: $0) }
            ?? JarvisConfig()
        detection = defaults.data(forKey: Self.detectionKey).flatMap { try? JSONDecoder().decode(Detection.self, from: $0) }
        secrets = Keychain.load(JarvisSecrets.self, for: Self.secretsKey) ?? JarvisSecrets()
        navidrome = Keychain.load(NavidromeAccount.self, for: "navidrome") ?? NavidromeAccount()
        voice = Keychain.load(VoiceSettings.self, for: "voice") ?? VoiceSettings()
        TrustDelegate.shared.setTrusted(host: host(of: config.address), trusted: config.trustSelfSigned)
    }

    var isConfigured: Bool {
        !ServerAddress.normalize(config.address).isEmpty
    }

    var client: JarvisClient {
        JarvisClient(address: config.address, secrets: secrets)
    }

    /// Fills in what "Detect automatically" found. Call `detection` first when it's nil.
    var endpoint: ResolvedEndpoint {
        let style: APIStyle = config.style == .auto ? (detection?.style ?? .custom) : config.style
        let usesDetection = config.style == .auto || config.style == detection?.style
        let detectedPath = usesDetection ? detection?.chatPath : nil
        let detectedField = usesDetection ? detection?.messageField : nil
        let model = config.model.trimmingCharacters(in: .whitespaces)
        return ResolvedEndpoint(
            style: style,
            model: model.isEmpty ? (detection?.models.first ?? "default") : model,
            chatPath: detectedPath ?? config.chatPath,
            messageField: detectedField ?? config.messageField
        )
    }

    private func applyTrust(old: JarvisConfig) {
        if old.address != config.address {
            TrustDelegate.shared.setTrusted(host: host(of: old.address), trusted: false)
        }
        TrustDelegate.shared.setTrusted(host: host(of: config.address), trusted: config.trustSelfSigned)
    }

    private func host(of address: String) -> String? {
        URL(string: ServerAddress.normalize(address))?.host
    }
}
