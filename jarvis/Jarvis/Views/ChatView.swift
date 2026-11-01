import SwiftUI
import UIKit

struct ChatView: View {
    var openSettings: () -> Void

    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var speaker: Speaker
    @StateObject private var listener = SpeechRecognizer()
    @ObservedObject private var music = MusicPlayer.shared
    @State private var musicWasPlaying = false
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let suggestions = ["How is the NAS doing?", "Anything on the cameras today?", "What can you do?"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if chat.turns.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(chat.turns) { turn in
                                    MessageBubble(turn: turn, isStreaming: chat.isSending && turn.id == chat.turns.last?.id,
                                                  onRetry: { chat.retry(settings: settings, onReply: replyFinished(false)) },
                                                  onSpeak: { speaker.speak(turn.text, audio: turn.audioURL, client: settings.client) })
                                        .id(turn.id)
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.turns.last?.text) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: chat.turns.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                if let error = listener.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                if music.hasQueue {
                    NowPlayingBar(music: music)
                }
                inputBar
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Jarvis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    StatusDot(status: chat.health)
                        .onTapGesture { Task { await chat.checkHealth(settings: settings) } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        speaker.stop()
                        chat.newChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(chat.turns.isEmpty)
                }
            }
            .task(id: settings.config.address) {
                await chat.checkHealth(settings: settings)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 60)
            ReactorRing(active: chat.isSending || listener.isRecording)
                .frame(width: 150, height: 150)
            Text("How can I help?")
                .font(.title2.weight(.semibold))
            if case .offline(let message) = chat.health {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            send(suggestion, viaVoice: false)
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Theme.surface, in: Capsule())
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                toggleListening()
            } label: {
                Image(systemName: listener.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(listener.isRecording ? Theme.danger : Theme.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .disabled(chat.isSending)
            .accessibilityLabel(listener.isRecording ? "Stop listening and send" : "Talk to Jarvis")

            TextField(listener.isRecording ? "Listening…" : "Message Jarvis", text: listener.isRecording ? .constant(listener.transcript) : $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .disabled(listener.isRecording)
                .submitLabel(.send)
                .onSubmit { send(draft, viaVoice: false) }

            if chat.isSending {
                Button {
                    chat.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 34))
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    send(draft, viaVoice: false)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    private func toggleListening() {
        if listener.isRecording {
            let heard = listener.stop()
            // Music was paused so the microphone could hear you; carry on unless you asked to change it.
            let command = MusicCommand.parse(heard)
            if command == nil || command == .nowPlaying {
                music.restoreAfterListening(wasPlaying: musicWasPlaying)
            }
            if !heard.isEmpty { send(heard, viaVoice: true) }
        } else {
            speaker.stop()
            inputFocused = false
            musicWasPlaying = music.isPlaying
            if music.isPlaying { music.pause() }
            Task { await listener.start() }
        }
    }

    private func send(_ text: String, viaVoice: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chat.isSending else { return }
        draft = ""
        // Music requests are handled on the phone, straight from Navidrome.
        if let command = MusicCommand.parse(text) {
            let replyID = chat.beginLocal(text)
            let account = settings.navidrome
            let mode = settings.config.speakMode
            Task {
                let reply = await MusicDJ.handle(command, account: account)
                chat.finishLocal(replyID, reply: reply)
                if let reply {
                    if !command.startsMusic && (mode == .always || (mode == .afterVoice && viaVoice)) {
                        speaker.speak(reply)
                    }
                } else {
                    chat.send(text, settings: settings, onReply: replyFinished(viaVoice))
                }
            }
            return
        }
        chat.send(text, settings: settings, onReply: replyFinished(viaVoice))
    }

    private func replyFinished(_ viaVoice: Bool) -> (String, URL?) -> Void {
        let mode = settings.config.speakMode
        let speaker = speaker
        let client = settings.client
        return { reply, audio in
            if mode == .always || (mode == .afterVoice && viaVoice) {
                speaker.speak(reply, audio: audio, client: client)
            }
        }
    }
}

struct MessageBubble: View {
    let turn: ChatTurn
    let isStreaming: Bool
    let onRetry: () -> Void
    let onSpeak: () -> Void

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if turn.text.isEmpty && isStreaming {
                    TypingDots()
                } else {
                    Text(Self.markdown(turn.text))
                        .textSelection(.enabled)
                        .foregroundStyle(turn.failed ? Theme.warning : .white)
                }
                if turn.failed {
                    Button("Try again", action: onRetry)
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(turn.role == .user ? Theme.userBubble : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = turn.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if turn.role == .assistant && !turn.failed {
                    Button(action: onSpeak) {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                    }
                }
            }
            if turn.role == .assistant { Spacer(minLength: 40) }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.secondaryText)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
    }
}

struct StatusDot: View {
    let status: HealthStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status {
        case .online: return Theme.good
        case .offline: return Theme.danger
        case .checking, .unknown: return Theme.secondaryText
        }
    }

    private var label: String {
        switch status {
        case .online: return "Online"
        case .offline: return "Offline"
        case .checking: return "Checking…"
        case .unknown: return ""
        }
    }
}

/// The glowing ring on the empty chat screen. Spins while Jarvis is busy or listening.
struct ReactorRing: View {
    var active: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.accent.opacity(0.9), lineWidth: 5)
                .shadow(color: Theme.accent, radius: 12)
            Circle()
                .trim(from: 0, to: 0.08)
                .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .padding(18)
                .rotationEffect(.degrees(spin ? 360 : 0))
            ForEach(0..<9) { index in
                Circle()
                    .trim(from: 0, to: 0.07)
                    .stroke(Theme.accent.opacity(0.6), lineWidth: 12)
                    .padding(18)
                    .rotationEffect(.degrees(Double(index) * 40 + (spin ? 360 : 0)))
            }
            Circle()
                .fill(Color.white)
                .padding(52)
                .shadow(color: Theme.accent, radius: active ? 26 : 14)
        }
        .animation(.linear(duration: active ? 2 : 12).repeatForever(autoreverses: false), value: spin)
        .onAppear { spin = true }
    }
}

/// What's playing from Navidrome, above the message box.
struct NowPlayingBar: View {
    @ObservedObject var music: MusicPlayer

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = music.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 40, height: 40)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(music.current?.displayTitle ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(music.current?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Button { music.togglePlayPause() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
            Button { music.next() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .accessibilityLabel("Next song")
            Button { music.stop() } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityLabel("Stop music")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}
