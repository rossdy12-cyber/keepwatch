import AVFoundation

/// Reads Jarvis's replies out loud: in Jarvis's own voice when the core sends a recording,
/// otherwise with the iPhone's British English voice.
@MainActor
final class Speaker: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var loading: Task<Void, Never>?

    func speak(_ text: String, audio: URL? = nil, client: JarvisClient? = nil) {
        stop()
        guard let audio, let client else {
            speakWithSystemVoice(text)
            return
        }
        loading = Task { [weak self] in
            do {
                let data = try await client.fetchAudio(audio)
                guard !Task.isCancelled, let self else { return }
                self.activatePlayback()
                let player = try AVAudioPlayer(data: data)
                self.player = player
                player.play()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.speakWithSystemVoice(text)
            }
        }
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

    private func speakWithSystemVoice(_ text: String) {
        let plain = Self.plainText(text)
        guard !plain.isEmpty else { return }
        activatePlayback()
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
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
