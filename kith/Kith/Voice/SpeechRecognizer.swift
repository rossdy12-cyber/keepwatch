import AVFoundation
import Speech
import SwiftUI

/// Hold-to-talk speech to text. Transcribes while recording; `stop()` returns the final text.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let engine = AVAudioEngine()

    func start() async {
        error = nil
        transcript = ""
        let speechAuth = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechAuth == .authorized else { error = "Speech recognition isn't allowed. Enable it in Settings."; return }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else { error = "Microphone access is off. Enable it in Settings."; return }
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available."; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let self, let result else { return }
                Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
            }
        } catch {
            self.error = "Couldn't start listening."
            isRecording = false
        }
    }

    @discardableResult
    func stop() -> String {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
