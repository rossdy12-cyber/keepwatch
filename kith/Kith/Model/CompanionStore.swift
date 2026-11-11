import Foundation

/// Holds the user's companions and each one's chat history, persisted locally.
@MainActor
final class CompanionStore: ObservableObject {
    @Published var companions: [Companion] { didSet { saveCompanions() } }
    @Published var activeID: UUID? { didSet { if let id = activeID { UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey) } } }
    @Published private(set) var messages: [UUID: [Message]] = [:]
    @Published var userName: String { didSet { UserDefaults.standard.set(userName, forKey: "kith.userName") } }

    private static let companionsKey = "kith.companions"
    private static let activeKey = "kith.activeID"
    private static let messagesKey = "kith.messages"

    init() {
        let defaults = UserDefaults.standard
        companions = defaults.data(forKey: Self.companionsKey)
            .flatMap { try? JSONDecoder().decode([Companion].self, from: $0) } ?? []
        activeID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init)
        userName = defaults.string(forKey: "kith.userName") ?? ""
        if let raw = defaults.data(forKey: Self.messagesKey),
           let decoded = try? JSONDecoder().decode([String: [Message]].self, from: raw) {
            for (key, value) in decoded { if let id = UUID(uuidString: key) { messages[id] = value } }
        }
        if activeID == nil { activeID = companions.first?.id }
    }

    var active: Companion? {
        companions.first { $0.id == activeID } ?? companions.first
    }

    func upsert(_ companion: Companion) {
        if let i = companions.firstIndex(where: { $0.id == companion.id }) { companions[i] = companion }
        else { companions.append(companion); activeID = companion.id }
    }

    func delete(_ companion: Companion) {
        companions.removeAll { $0.id == companion.id }
        messages[companion.id] = nil
        saveMessages()
        if activeID == companion.id { activeID = companions.first?.id }
    }

    func history(_ id: UUID) -> [Message] { messages[id] ?? [] }

    func add(_ message: Message, to id: UUID) {
        messages[id, default: []].append(message)
        saveMessages()
    }

    func updateLast(to id: UUID, text: String, failed: Bool) {
        guard var list = messages[id], let last = list.indices.last else { return }
        list[last].text = text
        list[last].failed = failed
        messages[id] = list
        saveMessages()
    }

    func clearHistory(_ id: UUID) { messages[id] = []; saveMessages() }

    private func saveCompanions() {
        if let data = try? JSONEncoder().encode(companions) { UserDefaults.standard.set(data, forKey: Self.companionsKey) }
    }
    private func saveMessages() {
        let encodable = Dictionary(uniqueKeysWithValues: messages.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) { UserDefaults.standard.set(data, forKey: Self.messagesKey) }
    }
}
