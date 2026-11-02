import AVFoundation
import Foundation

/// Which voice Jarvis speaks with. Kept in the Keychain (it holds the voice hub's key).
struct VoiceSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case automatic, hub, iphone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .hub: return "NAS voice (natural)"
            case .iphone: return "iPhone voice"
            }
        }
    }

    var mode: Mode = .automatic
    /// The jarvis-voice app on TrueNAS (its logs show the address and key).
    var hubAddress = "http://100.85.127.42:10701"
    var hubKey = ""
    /// A specific iPhone voice, or nil for the best British voice installed.
    var iphoneVoiceID: String?

    var hubConfigured: Bool { !hubKey.isEmpty && !ServerAddress.normalize(hubAddress, defaultScheme: "http").isEmpty }

    func hubSpeechURL(for text: String) -> URL? {
        guard var components = URLComponents(string: ServerAddress.normalize(hubAddress, defaultScheme: "http") + "/tts") else { return nil }
        components.queryItems = [URLQueryItem(name: "token", value: hubKey), URLQueryItem(name: "text", value: text)]
        return components.url
    }

    /// The iPhone voice to use: the chosen one, else the best British male voice installed
    /// (Premium, then Enhanced; Arthur and Daniel preferred).
    func iphoneVoice() -> AVSpeechSynthesisVoice? {
        if let id = iphoneVoiceID, let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return Self.bestBritishVoice()
    }

    static func bestBritishVoice() -> AVSpeechSynthesisVoice? {
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        let preferredNames = ["Arthur", "Daniel", "Oliver", "Malcolm"]
        return british.max { score($0, preferredNames) < score($1, preferredNames) } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    private static func score(_ voice: AVSpeechSynthesisVoice, _ names: [String]) -> Int {
        var value = voice.quality.rawValue * 100
        if voice.gender == .male { value += 20 }
        if let index = names.firstIndex(where: { voice.name.hasPrefix($0) }) { value += 10 - index }
        return value
    }

    /// English voices for the picker, best first.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.language == "en-GB" ? 1 : 0, $0.quality.rawValue, $0.name) > ($1.language == "en-GB" ? 1 : 0, $1.quality.rawValue, $1.name) }
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = " (Premium)"
        case .enhanced: quality = " (Enhanced)"
        default: quality = ""
        }
        let region = voice.language.replacingOccurrences(of: "en-", with: "")
        return "\(voice.name)\(quality) · \(region)"
    }
}
