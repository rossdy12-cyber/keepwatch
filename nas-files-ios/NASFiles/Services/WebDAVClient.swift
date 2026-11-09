import Foundation

enum WebDAVError: LocalizedError {
    case notConfigured
    case invalidURL
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Configure the WebDAV server, username, and password in Settings."
        case .invalidURL:
            return "The WebDAV server URL is invalid."
        case .requestFailed(let code):
            return "WebDAV request failed with HTTP status \(code)."
        case .invalidResponse:
            return "The WebDAV server returned an unexpected response."
        }
    }
}

@MainActor
struct WebDAVClient {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        guard settings.isConfigured, let baseURL = settings.serverProfile.normalizedBaseURL else {
            throw WebDAVError.notConfigured
        }

        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path

        guard let url = URL(string: baseURL.absoluteString + encodedPath) else {
            throw WebDAVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 30
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let credentials = "\(settings.username):\(settings.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.requestFailed(http.statusCode)
        }

        return WebDAVResponseParser.parse(data: data, baseURL: baseURL, currentPath: path)
    }

    func download(
        _ file: RemoteFile,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        guard settings.isConfigured, let baseURL = settings.serverProfile.normalizedBaseURL else {
            throw WebDAVError.notConfigured
        }

        let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path

        guard let url = URL(string: baseURL.absoluteString + encodedPath) else {
            throw WebDAVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 300

        let credentials = "\(settings.username):\(settings.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WebDAVError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = directory.appendingPathComponent(file.name)

        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        var buffer = Data()
        var received: Int64 = 0
        let expected = response.expectedContentLength

        defer {
            try? handle.close()
        }

        for try await byte in bytes {
            buffer.append(byte)
            received += 1

            if buffer.count >= 1_048_576 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll()

                if expected > 0, let progress {
                    progress(min(Double(received) / Double(expected) * 100, 100))
                }
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        if expected > 0, let progress {
            progress(100)
        }

        return destination
    }

    func upload(_ fileURL: URL, to directory: String) async throws {
        guard settings.isConfigured, let baseURL = settings.serverProfile.normalizedBaseURL else {
            throw WebDAVError.notConfigured
        }

        let fileName = fileURL.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent

        let encodedDirectory = directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory

        guard let url = URL(string: baseURL.absoluteString + encodedDirectory + "/" + fileName) else {
            throw WebDAVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600

        let credentials = "\(settings.username):\(settings.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)

        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.requestFailed(http.statusCode)
        }
    }

    func rename(_ file: RemoteFile, to newName: String) async throws {
        try await move(file, to: parentDirectory(of: file), newName: newName)
    }

    func move(_ file: RemoteFile, to directory: String) async throws {
        try await move(file, to: directory, newName: file.name)
    }

    func delete(_ file: RemoteFile) async throws {
        guard settings.isConfigured, let baseURL = settings.serverProfile.normalizedBaseURL else {
            throw WebDAVError.notConfigured
        }

        let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path

        guard let url = URL(string: baseURL.absoluteString + encodedPath) else {
            throw WebDAVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60

        let credentials = "\(settings.username):\(settings.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WebDAVError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func move(
        _ file: RemoteFile,
        to directory: String,
        newName: String
    ) async throws {
        guard settings.isConfigured, let baseURL = settings.serverProfile.normalizedBaseURL else {
            throw WebDAVError.notConfigured
        }

        let encodedSource = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        let encodedDirectory = directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory
        let encodedName = newName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newName

        guard let source = URL(string: baseURL.absoluteString + encodedSource),
              let destination = URL(string: baseURL.absoluteString + encodedDirectory + "/" + encodedName) else {
            throw WebDAVError.invalidURL
        }

        var request = URLRequest(url: source)
        request.httpMethod = "MOVE"
        request.timeoutInterval = 60
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")

        let credentials = "\(settings.username):\(settings.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WebDAVError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func parentDirectory(of file: RemoteFile) -> String {
        let path = file.path
        let parent = (path as NSString).deletingLastPathComponent

        return parent.isEmpty ? "/" : parent
    }
}

private final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private var files: [RemoteFile] = []
    private var currentPath: String?
    private var currentName: String?
    private var currentIsDirectory = false
    private var currentSize: Int64 = 0
    private var currentDate: Date?
    private var currentContentType: String?
    private var baseURL: URL
    private var currentPathBase: String
    private var elementText = ""

    private init(baseURL: URL, currentPath: String) {
        self.baseURL = baseURL
        self.currentPathBase = currentPath
    }

    static func parse(data: Data, baseURL: URL, currentPath: String) -> [RemoteFile] {
        let parser = WebDAVResponseParser(baseURL: baseURL, currentPath: currentPath)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()

        return parser.files.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }

            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementText = ""

        if elementName.lowercased().hasSuffix("response") {
            currentPath = nil
            currentName = nil
            currentIsDirectory = false
            currentSize = 0
            currentDate = nil
            currentContentType = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        elementText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? ""

        switch localName {
        case "href":
            currentPath = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "displayname":
            currentName = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getcontentlength":
            currentSize = Int64(elementText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        case "getlastmodified":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            currentDate = formatter.date(from: elementText.trimmingCharacters(in: .whitespacesAndNewlines))
        case "getcontenttype":
            currentContentType = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "collection":
            currentIsDirectory = true
        case "response":
            finishCurrentItem()
        default:
            break
        }
    }

    private func finishCurrentItem() {
        guard let href = currentPath, let decoded = href.removingPercentEncoding else {
            return
        }

        let isDirectory = currentIsDirectory
        var name = currentName ?? URL(string: decoded)?.lastPathComponent ?? ""

        if name.isEmpty {
            name = (decoded as NSString).lastPathComponent
        }

        if isDirectory, name.isEmpty {
            name = "/"
        }

        let normalisedCurrent = currentPathBase.hasSuffix("/") ? currentPathBase : currentPathBase + "/"

        if decoded == normalisedCurrent || decoded == currentPathBase {
            return
        }

        let file = RemoteFile(
            id: decoded,
            name: name,
            path: decoded,
            isDirectory: isDirectory,
            size: currentSize,
            modifiedDate: currentDate,
            contentType: currentContentType
        )

        files.append(file)
    }
}
