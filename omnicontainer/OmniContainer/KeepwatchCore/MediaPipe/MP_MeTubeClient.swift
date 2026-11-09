import Foundation

struct MPMeTubeFormat: Identifiable, Hashable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

enum MPMeTubeError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case requestFailed(Int)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The MeTube server URL is invalid."
        case .invalidResponse:
            return "MeTube returned an unexpected response."
        case .requestFailed(let statusCode):
            return "MeTube request failed with HTTP status \(statusCode)."
        case .missingToken:
            return "An API token is required for this MeTube server."
        }
    }
}

@MainActor
struct MPMeTubeClient {
    private let settings: MPAppSettings

    init(settings: MPAppSettings) {
        self.settings = settings
    }

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let baseURL = settings.serverProfile.normalizedBaseURL else {
            throw MPMeTubeError.invalidServerURL
        }

        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw MPMeTubeError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if settings.serverProfile.usesToken {
            guard !settings.apiToken.isEmpty else {
                throw MPMeTubeError.missingToken
            }

            request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = body
        return request
    }

    func fetchFormats() async throws -> [MPMeTubeFormat] {
        let request = try makeRequest(path: "/formats")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MPMeTubeError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MPMeTubeError.requestFailed(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MPMeTubeError.invalidResponse
        }

        var formats: [MPMeTubeFormat] = []

        for (key, value) in json {
            let title: String

            if let dictionary = value as? [String: Any],
               let label = dictionary["title"] as? String {
                title = label
            } else {
                title = key
            }

            formats.append(MPMeTubeFormat(id: key, title: title))
        }

        return formats.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func addDownload(
        url: String,
        outputType: MPOutputType,
        quality: String,
        folder: String
    ) async throws {
        let payload: [String: Any] = [
            "url": url,
            "format": outputType == .audio ? "audio" : "video",
            "quality": quality,
            "folder": folder,
            "custom_name_prefix": ""
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = try makeRequest(path: "/add", method: "POST", body: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MPMeTubeError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MPMeTubeError.requestFailed(http.statusCode)
        }
    }
}
