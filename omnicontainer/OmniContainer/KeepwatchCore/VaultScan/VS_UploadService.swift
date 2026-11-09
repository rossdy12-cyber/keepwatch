import Foundation

enum VSUploadError: LocalizedError {
    case notConfigured
    case invalidURL
    case requestFailed(Int)
    case missingLocalFile

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Configure the WebDAV server, username, and password in Settings."
        case .invalidURL:
            return "The WebDAV server URL is invalid."
        case .requestFailed(let code):
            return "Upload failed with HTTP status \(code)."
        case .missingLocalFile:
            return "The scanned PDF could not be found on this device."
        }
    }
}

@MainActor
struct VSUploadService {
    private let settings: VSAppSettings

    init(settings: VSAppSettings) {
        self.settings = settings
    }

    func upload(
        _ document: VSScannedDocument,
        pdfData: Data,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        guard settings.isConfigured, let baseURL = settings.normalizedBaseURL else {
            throw VSUploadError.notConfigured
        }

        let remotePath = remotePath(for: document)
        let baseStr = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let credentials = "\(settings.username):\(settings.password)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()

        // Ensure WebDAV parent directories exist via MKCOL before PUT
        let segments = remotePath.split(separator: "/").dropLast()
        var currentDir = baseStr
        for seg in segments {
            currentDir += "/\(seg)"
            if let mkURL = URL(string: currentDir + "/") {
                var mkReq = URLRequest(url: mkURL)
                mkReq.httpMethod = "MKCOL"
                mkReq.timeoutInterval = 15
                mkReq.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
                _ = try? await URLSession.shared.data(for: mkReq)
            }
        }

        guard let url = URL(string: baseStr + "/" + remotePath) else {
            throw VSUploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")

        let delegate = VSUploadProgressDelegate(progress: progress)
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        defer {
            session.finishTasksAndInvalidate()
        }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
            delegate.continuation = continuation

            let task = session.uploadTask(with: request, from: pdfData)
            task.resume()
        }

        guard let http = response as? HTTPURLResponse else {
            throw VSUploadError.invalidURL
        }

        guard (200..<300).contains(http.statusCode) else {
            throw VSUploadError.requestFailed(http.statusCode)
        }
    }

    private func remotePath(for document: VSScannedDocument) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"

        let datePath = formatter.string(from: document.documentDate)
        let folder = settings.remoteFolder
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: " ", with: "-")

        return "\(folder)/\(datePath)/\(document.pdfFileName)"
    }
}

private final class VSUploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progress: ((Double) -> Void)?
    var continuation: CheckedContinuation<URLResponse, Error>?

    init(progress: ((Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else {
            return
        }

        progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 100)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }

        if let response = task.response {
            continuation?.resume(returning: response)
        } else {
            continuation?.resume(throwing: VSUploadError.invalidURL)
        }

        continuation = nil
    }
}
