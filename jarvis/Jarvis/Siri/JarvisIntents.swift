import AppIntents
import Foundation
import UIKit
import UserNotifications

/// "Hey Siri, ask Jarvis" → "What would you like?" → your request.
/// Music requests play from Navidrome in the background; anything else goes to the Jarvis core and Siri reads the reply.
/// Conforms to AudioPlaybackIntent so iOS lets it start music without opening the app.
struct AskJarvisIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Ask Jarvis"
    static var description = IntentDescription("Ask Jarvis anything, or ask it to play music from Navidrome.")
    static var openAppWhenRun = false

    @Parameter(title: "Request", requestValueDialog: IntentDialog("What would you like?"))
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await JarvisVoice.answer(request)
        return .result(dialog: "\(reply)")
    }
}

struct ShuffleMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle my music"
    static var description = IntentDescription("Shuffle your Navidrome library.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await MusicDJ.handle(.shuffleAll, account: JarvisSettings.shared.navidrome) ?? "Couldn't start the music."
        return .result(dialog: "\(reply)")
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Pause music"
    static var description = IntentDescription("Pause the music Jarvis is playing.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await MusicDJ.handle(.pause, account: JarvisSettings.shared.navidrome) ?? "Paused."
        return .result(dialog: "\(reply)")
    }
}

struct NextSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next song"
    static var description = IntentDescription("Skip to the next song.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await MusicDJ.handle(.next, account: JarvisSettings.shared.navidrome) ?? "Skipped."
        return .result(dialog: "\(reply)")
    }
}

/// The Siri phrases. Each has to include the app's name; Siri then asks for anything else it needs.
struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: ["Ask \(.applicationName)", "Talk to \(.applicationName)", "Tell \(.applicationName)", "Hey \(.applicationName)"],
            shortTitle: "Ask Jarvis",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: ShuffleMusicIntent(),
            phrases: ["Shuffle music in \(.applicationName)", "Play music with \(.applicationName)", "Shuffle my music in \(.applicationName)"],
            shortTitle: "Shuffle music",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PauseMusicIntent(),
            phrases: ["Pause \(.applicationName)", "Pause music in \(.applicationName)"],
            shortTitle: "Pause music",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextSongIntent(),
            phrases: ["Next song in \(.applicationName)", "Skip song in \(.applicationName)"],
            shortTitle: "Next song",
            systemImageName: "forward.fill"
        )
    }
}

/// Answers a request outside the chat screen (Siri, the Action Button), and records it in the chat.
@MainActor
enum JarvisVoice {
    static func answer(_ text: String) async -> String {
        let settings = JarvisSettings.shared
        let chat = ChatStore.shared
        if let command = MusicCommand.parse(text), let reply = await MusicDJ.handle(command, account: settings.navidrome) {
            chat.addExchange(user: text, reply: reply)
            return reply
        }

        // The Jarvis core can take 10 seconds or more, and Siri gives up on an app at about that point.
        // Wait up to 8 seconds; if the answer isn't ready, finish in the background and send it as a notification.
        let work = Task { @MainActor in await coreReply(text) }
        let quick: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await work.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let quick { return quick }

        let background = BackgroundTask()
        background.begin()
        Task { @MainActor in
            let reply = await work.value
            await notify(reply)
            background.end()
        }
        return "Give me a moment, I'll send the answer as a notification."
    }

    /// Asks the Jarvis core and records the exchange in the chat.
    private static func coreReply(_ text: String) async -> String {
        let settings = JarvisSettings.shared
        let chat = ChatStore.shared
        do {
            if settings.config.style == .auto && settings.detection == nil {
                settings.detection = try await settings.client.detect()
            }
            let history = chat.turns.filter { !$0.failed } + [ChatTurn(role: .user, text: text)]
            var reply = ""
            for try await part in settings.client.reply(history: history, endpoint: settings.endpoint,
                                                        systemPrompt: settings.config.systemPrompt, sessionID: chat.sessionID) {
                if case .text(let chunk) = part { reply += chunk }
            }
            chat.addExchange(user: text, reply: reply)
            return Speaker.plainText(reply)
        } catch {
            return describe(error)
        }
    }

    private static func notify(_ reply: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Jarvis"
        content.body = reply
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Asks iOS for a little time to finish a reply after Siri has moved on.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Jarvis reply") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
