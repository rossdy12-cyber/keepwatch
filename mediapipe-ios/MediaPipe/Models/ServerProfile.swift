import Foundation

struct ServerProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var baseURL: String
    var usesToken: Bool

    init(
        id: UUID = UUID(),
        name: String = "MeTube",
        baseURL: String = "",
        usesToken: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.usesToken = usesToken
    }

    var normalizedBaseURL: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return nil
        }

        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }

        return URL(string: trimmed)
    }
}
