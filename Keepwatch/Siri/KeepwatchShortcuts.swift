import AppIntents
import Foundation
import UIKit
import UserNotifications

// MARK: - Jarvis Voice & Music Intents

struct AskJarvisIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Ask Jarvis"
    static var description = IntentDescription("Ask Jarvis anything, or ask it to play music from Navidrome.")
    static var openAppWhenRun = false

    @Parameter(title: "Request", requestValueDialog: IntentDialog("What would you like?"))
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = request
        let reply = await JarvisVoice.answer(text)
        if let command = MusicCommand.parse(text), command.startsMusic, !MusicPlayer.shared.lastStartAllowed {
            throw needsToContinueInForegroundError("Open Keepwatch to start the music?") {
                _ = await MusicDJ.handle(command, account: JarvisSettings.shared.navidrome)
            }
        }
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

// MARK: - Paydays Spend Logging & Balance Intents (Bypasses missing iOS 27 Wallet Trigger)

struct LogPaydaysSpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Paydays Spend"
    static var description = IntentDescription("Log a payment to Paydays on TrueNAS and hear what's left until payday.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount (£)", requestValueDialog: IntentDialog("How much did you spend in pounds?"))
    var amount: Double

    @Parameter(title: "Merchant / Shop", default: "Apple Pay", requestValueDialog: IntentDialog("Where did you spend it?"))
    var merchant: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let reply = try await PaydaysStore.shared.logSpend(amountPounds: amount, merchant: merchant)
            return .result(dialog: "\(reply)")
        } catch {
            return .result(dialog: "\(describe(error))")
        }
    }
}

struct CheckPaydaysBalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Safe to Spend"
    static var description = IntentDescription("Check how much is left until your next payday.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PaydaysStore.shared.refresh()
        let line = PaydaysStore.shared.statusLine()
        return .result(dialog: "\(line)")
    }
}

// MARK: - Drop-to-NAS Share Sheet, House Broadcast, Camera & Handover Intents (#1, #2, #7, #8, #15)

struct DropToNASIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Link or Search to NAS"
    static var description = IntentDescription("Send a shared video, audio, gallery, Mega link, or Soulseek music search straight to your TrueNAS downloaders.")
    static var openAppWhenRun = false

    @Parameter(title: "URL or Search Query", requestValueDialog: IntentDialog("Paste or speak the link or album to send to your NAS"))
    var urlOrQuery: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await HomelabBridgeStore.shared.dropToNAS(urlOrQuery: urlOrQuery, target: "auto")
        return .result(dialog: "\(msg)")
    }
}

struct BroadcastHouseIntent: AppIntent {
    static var title: LocalizedStringResource = "Broadcast to House Speaker"
    static var description = IntentDescription("Speak an announcement over your Raspberry Pi / Kokoro voice hub and Jarvis intercom.")
    static var openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: IntentDialog("What should Jarvis announce to the house?"))
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await HomelabBridgeStore.shared.broadcastToHouse(message: message)
        return .result(dialog: "Announced to house: \(message)")
    }
}

struct ToggleCameraAlertsIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Camera Home / Away Alerts"
    static var description = IntentDescription("Mute or unmute Frigate camera ntfy alerts when arriving home or leaving.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await HomelabBridgeStore.shared.cameraAction("toggle_alerts")
        let msg = HomelabBridgeStore.shared.statusBanner ?? "Toggled camera alerts."
        return .result(dialog: "\(msg)")
    }
}

struct HandoverChecklistIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Handover Schedule"
    static var description = IntentDescription("Read out pending Lauren & Ross handover items and shared checklist tasks.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await HomelabBridgeStore.shared.loadSystemBridge()
        let pending = HomelabBridgeStore.shared.sharedNotes.filter { !$0.done }.map(\.text)
        let summary = pending.isEmpty
            ? "All shared handover checklist tasks are complete!"
            : "Pending tasks: " + pending.joined(separator: "; ")
        return .result(dialog: "\(summary)")
    }
}

// MARK: - Unified App Shortcuts Provider

struct KeepwatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
                "Ask Jarvis in \(.applicationName)"
            ],
            shortTitle: "Ask Jarvis",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: LogPaydaysSpendIntent(),
            phrases: [
                "Log spend in \(.applicationName)",
                "Add payment in \(.applicationName)",
                "I spent money in \(.applicationName)"
            ],
            shortTitle: "Log Paydays Spend",
            systemImageName: "sterlingsign.circle"
        )
        AppShortcut(
            intent: CheckPaydaysBalanceIntent(),
            phrases: [
                "Check budget in \(.applicationName)",
                "Safe to spend in \(.applicationName)",
                "How much left in \(.applicationName)"
            ],
            shortTitle: "Safe to Spend",
            systemImageName: "shield.checkered"
        )
        AppShortcut(
            intent: DropToNASIntent(),
            phrases: [
                "Send to NAS in \(.applicationName)",
                "Download with \(.applicationName)"
            ],
            shortTitle: "Drop to NAS",
            systemImageName: "tray.and.arrow.down.fill"
        )
        AppShortcut(
            intent: BroadcastHouseIntent(),
            phrases: [
                "Announce to house in \(.applicationName)",
                "Broadcast with \(.applicationName)"
            ],
            shortTitle: "House Broadcast",
            systemImageName: "megaphone.fill"
        )
        AppShortcut(
            intent: ToggleCameraAlertsIntent(),
            phrases: [
                "Toggle camera alerts in \(.applicationName)",
                "Home mode in \(.applicationName)"
            ],
            shortTitle: "Camera Alerts",
            systemImageName: "video.fill"
        )
        AppShortcut(
            intent: HandoverChecklistIntent(),
            phrases: [
                "Check handover in \(.applicationName)",
                "Handover schedule in \(.applicationName)"
            ],
            shortTitle: "Handover Status",
            systemImageName: "checklist.checked"
        )
        AppShortcut(
            intent: ShuffleMusicIntent(),
            phrases: [
                "Shuffle music in \(.applicationName)",
                "Play music with \(.applicationName)"
            ],
            shortTitle: "Shuffle music",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PauseMusicIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause music in \(.applicationName)"
            ],
            shortTitle: "Pause music",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextSongIntent(),
            phrases: [
                "Next song in \(.applicationName)",
                "Skip song in \(.applicationName)"
            ],
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
