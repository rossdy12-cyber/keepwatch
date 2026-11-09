import Foundation

struct PhotoPrismError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor PhotoPrismClient {
    private let baseURL: URL
    private var token: String?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    static func normaliseServerURL(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            throw PhotoPrismError(message: "Enter your PhotoPrism server address.")
        }

        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://\(text)"
        }

        guard let url = URL(string: text), let scheme = url.scheme, !(url.host()?.isEmpty ?? true) else {
            throw PhotoPrismError(message: "The server address is not valid.")
        }

        return url
    }

    func createSession(username: String, appPassword: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/v1/session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "username": username,
            "password": appPassword
        ])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)

        struct SessionResponse: Decodable {
            let id: String?
        }

        let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)

        guard let id = decoded.id, !id.isEmpty else {
            throw PhotoPrismError(message: "PhotoPrism did not return a valid session.")
        }

        token = id
        return id
    }

    func searchPhotos(query: String, count: Int = 100, offset: Int = 0) async throws -> (PhotoSearchResponse, String?) {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/photos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: "newest")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        addAuthorization(to: &request)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)

        let previewToken = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Preview-Token")
        let result = try JSONDecoder().decode(PhotoSearchResponse.self, from: data)
        return (result, previewToken)
    }

    nonisolated func thumbnailURL(for photo: Photo, previewToken: String?, size: Int = 480) -> URL? {
        guard let previewToken, !previewToken.isEmpty else { return nil }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/v1/t/\(photo.uid)/\(previewToken)/\(size)"
        return components.url
    }

    func uploadFile(at fileURL: URL, originalName: String) async throws {
        let escapedName = originalName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? originalName
        let uploadURL = baseURL.appendingPathComponent("api/v1/upload/\(escapedName)")

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        addAuthorization(to: &request)
        request.httpBody = try Data(contentsOf: fileURL)

        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    func importUploads() async throws {
        let url = baseURL.appendingPathComponent("api/v1/import/upload")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthorization(to: &request)

        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private func addAuthorization(to request: inout URLRequest) {
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PhotoPrismError(message: "The server response was invalid.")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw PhotoPrismError(message: "PhotoPrism returned HTTP \(http.statusCode). Check the server address, username, and app password.")
        }
    }
}
