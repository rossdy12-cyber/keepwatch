import AVFoundation

/// Reads Jarvis's replies out loud. In order of preference: the core's own recording, the natural NAS voice
/// (Kokoro, from the jarvis-voice app), then the best British voice installed on the iPhone.
@MainActor
final class Speaker: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var loading: Task<Void, Never>?

    func speak(_ text: String, audio: URL? = nil, client: JarvisClient? = nil) {
        stop()
        let voice = JarvisSettings.shared.voice
        let plain = Self.plainText(text)
        loading = Task { [weak self] in
            if let audio, let client, let data = try? await client.fetchAudio(audio) {
                guard !Task.isCancelled, let self else { return }
                if self.play(data) { return }
            }
            if voice.mode != .iphone, voice.hubConfigured, !plain.isEmpty, let data = await Self.hubSpeech(plain, voice) {
                guard !Task.isCancelled, let self else { return }
                if self.play(data) { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.speakWithSystemVoice(text, voice: voice)
        }
    }

    private func play(_ data: Data) -> Bool {
        activatePlayback()
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        self.player = player
        return player.play()
    }

    /// The natural voice from the jarvis-voice app on TrueNAS.
    private static func hubSpeech(_ text: String, _ voice: VoiceSettings) async -> Data? {
        guard let url = voice.hubSpeechURL(for: String(text.prefix(2000))) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        guard let result = try? await httpSession.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200, result.0.count > 44 else { return nil }
        return result.0
    }

    func stop() {
        loading?.cancel()
        loading = nil
        player?.stop()
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func speakWithSystemVoice(_ text: String, voice: VoiceSettings) {
        let plain = Self.plainText(text)
        guard !plain.isEmpty else { return }
        activatePlayback()
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = voice.iphoneVoice()
        // A touch slower and lower than the default: calmer, more butler than satnav.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 0.92
        synthesizer.speak(utterance)
    }

    private func activatePlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Drops Markdown symbols and code blocks so they aren't read out.
    static func plainText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code) ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
