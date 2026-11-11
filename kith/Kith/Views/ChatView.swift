import SwiftUI

struct ChatView: View {
    let companion: Companion
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var settings: KithSettings
    @EnvironmentObject private var speaker: Speaker
    @StateObject private var listener = SpeechRecognizer()
    @State private var draft = ""
    @State private var sending = false
    @State private var showEdit = false
    @State private var showMemory = false
    @FocusState private var focused: Bool

    private var current: Companion { store.companions.first { $0.id == companion.id } ?? companion }
    private var messages: [Message] { store.history(companion.id) }
    private var activity: CreatureActivity {
        speaker.isSpeaking ? .talking : (listener.isRecording ? .listening : .idle)
    }

    var body: some View {
        VStack(spacing: 0) {
            CreatureView(style: current.style, activity: activity)
                .frame(height: 150)
                .padding(.top, 6)
                .onTapGesture { if !sending { speaker.speak("Hi \(store.userName.isEmpty ? "there" : store.userName)!", voiceId: current.voiceId, pitch: current.pitch) } }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if messages.isEmpty {
                            Text("Say hi to \(current.name) 👋")
                                .font(.footnote).foregroundStyle(Theme.secondaryText).padding(.top, 30)
                        }
                        ForEach(messages) { message in
                            Bubble(message: message, name: current.name).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .onChange(of: messages.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: messages.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if let error = listener.error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            inputBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit \(current.name)", systemImage: "pencil") }
                    Button { showMemory = true } label: { Label("What they remember", systemImage: "brain") }
                    Button(role: .destructive) { store.clearHistory(companion.id) } label: { Label("Clear conversation", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onDisappear { speaker.stop() }
        .sheet(isPresented: $showEdit) { CustomizeView(companion: current, isNew: false) }
        .sheet(isPresented: $showMemory) { MemoryView(companion: current) }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { toggleMic() } label: {
                Image(systemName: listener.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(listener.isRecording ? .red : Theme.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .disabled(sending)

            TextField(listener.isRecording ? "Listening…" : "Message \(current.name)",
                      text: listener.isRecording ? .constant(listener.transcript) : $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .disabled(listener.isRecording)
                .onSubmit { send(draft) }

            Button { send(draft) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.background)
    }

    private func toggleMic() {
        if listener.isRecording {
            let heard = listener.stop()
            if !heard.isEmpty { send(heard) }
        } else {
            speaker.stop()
            focused = false
            Task { await listener.start() }
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        guard settings.isConfigured else {
            store.add(Message(fromUser: false, text: "Set your Jarvis core address in Settings so I can think.", failed: true), to: companion.id)
            return
        }
        draft = ""
        store.add(Message(fromUser: true, text: trimmed), to: companion.id)
        store.add(Message(fromUser: false, text: "…"), to: companion.id)
        sending = true
        let companionCopy = current
        Task {
            do {
                let reply = try await settings.client.reply(to: trimmed, companion: companionCopy, userName: store.userName)
                store.updateLast(to: companion.id, text: reply, failed: false)
                speaker.speak(reply, voiceId: companionCopy.voiceId, pitch: companionCopy.pitch)
            } catch {
                store.updateLast(to: companion.id, text: describeError(error), failed: true)
            }
            sending = false
        }
    }
}

private struct Bubble: View {
    let message: Message
    let name: String

    var body: some View {
        HStack {
            if message.fromUser { Spacer(minLength: 40) }
            Text(message.text)
                .foregroundStyle(message.failed ? .orange : (message.fromUser ? .white : .primary))
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(message.fromUser ? Theme.userBubble : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 17))
                .frame(maxWidth: 300, alignment: message.fromUser ? .trailing : .leading)
            if !message.fromUser { Spacer(minLength: 40) }
        }
    }
}
