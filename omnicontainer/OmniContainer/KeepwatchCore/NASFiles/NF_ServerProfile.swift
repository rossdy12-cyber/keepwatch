import Foundation

struct NFServerProfile: Codable, Hashable {
    var baseURL: String
    var username: String
    var usesPassword: Bool

    var normalizedBaseURL: URL? {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty {
            return nil
        }

        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://\(value)"
        }

        if !value.hasSuffix("/") {
            value += "/"
        }

        return URL(string: value)
    }
}
