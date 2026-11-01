import Foundation

/// The conversation with Jarvis. Saved on the phone so it survives restarts.
@MainActor
final class ChatStore: ObservableObject {
    private struct Saved: Codable {
        var sessionID: String
        var turns: [ChatTurn]
    }

    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isSending = false
    @Published var health: HealthStatus = .unknown

    private(set) var sessionID = UUID().uuidString
    private var task: Task<Void, Never>?

    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("jarvis-chat.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            turns = saved.turns
            sessionID = saved.sessionID
        }
    }

    /// Sends a message and streams the reply into the last bubble. Calls `onReply` with the full text when done.
    func send(_ text: String, settings: JarvisSettings, onReply: @escaping (String) -> Void = { _ in }) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }
        turns.append(ChatTurn(role: .user, text: message))
        let replyID = UUID()
        turns.append(ChatTurn(id: replyID, role: .assistant, text: ""))
        isSending = true

        task = Task { [weak self] in
            guard let self else { return }
            do {
                if settings.config.style == .auto && settings.detection == nil {
                    settings.detection = try await settings.client.detect()
                }
                let history = self.turns.filter { $0.id != replyID }
                let stream = settings.client.reply(history: history, endpoint: settings.endpoint,
                                                   systemPrompt: settings.config.systemPrompt, sessionID: self.sessionID)
                for try await chunk in stream {
                    self.update(replyID) { $0.text += chunk }
                }
                self.health = .online("Online")
                if let reply = self.turns.first(where: { $0.id == replyID })?.text {
                    onReply(reply)
                }
            } catch {
                if isCancellation(error) {
                    self.update(replyID) { if $0.text.isEmpty { $0.text = "Stopped." } }
                } else {
                    self.update(replyID) {
                        $0.failed = true
                        $0.text = $0.text.isEmpty ? describe(error) : $0.text + "\n\n⚠️ " + describe(error)
                    }
                }
            }
            self.isSending = false
            self.task = nil
            self.save()
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Re-sends the last thing you said.
    func retry(settings: JarvisSettings, onReply: @escaping (String) -> Void = { _ in }) {
        guard !isSending, let lastUser = turns.lastIndex(where: { $0.role == .user }) else { return }
        let text = turns[lastUser].text
        turns.removeSubrange(lastUser...)
        send(text, settings: settings, onReply: onReply)
    }

    func newChat() {
        stop()
        turns = []
        sessionID = UUID().uuidString
        save()
    }

    func checkHealth(settings: JarvisSettings) async {
        health = .checking
        health = await settings.client.health(path: settings.config.healthPath)
    }

    private func update(_ id: UUID, _ change: (inout ChatTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    private func save() {
        let saved = Saved(sessionID: sessionID, turns: Array(turns.suffix(200)))
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
