import Foundation

struct VaultItem: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isImage: Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"].contains(fileExtension)
    }

    var isVideo: Bool {
        ["mp4", "mov", "m4v"].contains(fileExtension)
    }
}

enum VaultError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Vault server URL is invalid."
        case .invalidResponse:
            return "The Vault server returned an invalid response."
        case .httpStatus(let status):
            return "Vault server returned HTTP \(status)."
        case .missingCredentials:
            return "Enter your Vault username and WebDAV password in Settings."
        }
    }
}

@MainActor
final class VaultModel: ObservableObject {
    @Published var settings = VaultSettings.load()
    @Published var items: [VaultItem] = []
    @Published var currentPath = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var connectionMessage: String?

    private let session = URLSession.shared

    private var authHeader: String? {
        guard !settings.username.isEmpty, !settings.password.isEmpty else {
            return nil
        }

        let credentials = "\(settings.username):\(settings.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()

        return "Basic \(encoded)"
    }

    func saveSettings() {
        settings.save()
    }

    func url(for path: String) throws -> URL {
        guard let base = settings.baseURL else {
            throw VaultError.invalidURL
        }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw VaultError.invalidURL
        }

        let basePath = components.path
            .split(separator: "/")
            .map(String.init)

        let itemPath = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        components.path = "/" + (basePath + itemPath).joined(separator: "/")

        guard let url = components.url else {
            throw VaultError.invalidURL
        }

        return url
    }

    func request(for item: VaultItem) -> URLRequest? {
        guard let url = try? url(for: item.path) else {
            return nil
        }

        var request = URLRequest(url: url)

        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        return request
    }

    func list(_ folder: String) async {
        isLoading = true
        errorMessage = nil
        currentPath = folder

        do {
            items = try await propfind(folder)
        } catch {
            errorMessage = error.localizedDescription
            items = []
        }

        isLoading = false
    }

    func testConnection() async {
        connectionMessage = nil

        do {
            _ = try await propfind("")
            connectionMessage = "Connected successfully."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func upload(data: Data, filename: String, folder: String) async throws {
        var request = URLRequest(url: try url(for: folder + "/" + filename))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        request.httpBody = data

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func createFolder(_ name: String, in folder: String) async throws {
        var request = URLRequest(url: try url(for: folder + "/" + name))
        request.httpMethod = "MKCOL"

        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func delete(_ item: VaultItem) async throws {
        var request = URLRequest(url: try url(for: item.path))
        request.httpMethod = "DELETE"

        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func download(_ item: VaultItem) async throws -> Data {
        var request = URLRequest(url: try url(for: item.path))

        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        try validate(response)

        return data
    }

    private func propfind(_ folder: String) async throws -> [VaultItem] {
        guard let auth = authHeader else {
            throw VaultError.missingCredentials
        }

        var request = URLRequest(url: try url(for: folder))
        request.httpMethod = "PROPFIND"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:">
            <d:prop>
                <d:displayname/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:resourcetype/>
            </d:prop>
        </d:propfind>
        """.utf8)

        let (data, response) = try await session.data(for: request)
        try validate(response)

        let basePath = settings.baseURL?.path ?? "/"

        return WebDAVParser(basePath: basePath, currentFolder: folder).parse(data)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VaultError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw VaultError.httpStatus(http.statusCode)
        }
    }
}

final class WebDAVParser: NSObject, XMLParserDelegate {
    private let basePath: String
    private let currentFolder: String
    private(set) var items: [VaultItem] = []

    private var currentElement = ""
    private var currentName = ""
    private var currentHref = ""
    private var currentSize: Int64 = 0
    private var currentModified: Date?
    private var isDirectory = false
    private var isFirstResponse = true

    init(basePath: String, currentFolder: String) {
        self.basePath = basePath
        self.currentFolder = currentFolder
    }

    func parse(data: Data) -> [VaultItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName

        if elementName.hasSuffix("response") {
            currentName = ""
            currentHref = ""
            currentSize = 0
            currentModified = nil
            isDirectory = false
        }

        if elementName.hasSuffix("collection") {
            isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return }

        if currentElement.hasSuffix("href") {
            currentHref += text
        } else if currentElement.hasSuffix("displayname") {
            currentName += text
        } else if currentElement.hasSuffix("getcontentlength") {
            currentSize = Int64(text) ?? 0
        } else if currentElement.hasSuffix("getlastmodified") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            currentModified = formatter.date(from: text)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName.hasSuffix("response") else { return }

        if isFirstResponse {
            isFirstResponse = false
            return
        }

        var relativePath = currentHref
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? currentHref

        if relativePath.hasPrefix(basePath) {
            relativePath.removeFirst(basePath.count)
        }

        relativePath = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let name = currentName.isEmpty
            ? (relativePath as NSString).lastPathComponent
            : currentName

        guard !name.isEmpty else { return }

        items.append(
            VaultItem(
                id: relativePath,
                name: name,
                path: relativePath,
                isDirectory: isDirectory,
                size: currentSize,
                modified: currentModified
            )
        )
    }
}
