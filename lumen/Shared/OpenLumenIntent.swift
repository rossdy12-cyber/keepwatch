import AppIntents

/// Opens Lumen: used by the Control Centre / Lock Screen / Action button control.
struct OpenLumenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Lumen"
    static let description = IntentDescription("Opens the Lumen camera.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
