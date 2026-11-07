import Foundation

/// A small bus for one-shot actions triggered from outside the UI (the Action Button / Shortcuts),
/// picked up by the chat screen when the app comes to the foreground.
@MainActor
final class AppActions: ObservableObject {
    static let shared = AppActions()

    /// Set by the "Talk to Jarvis" intent: the chat screen starts listening as soon as it appears.
    @Published var startListening = false
}
