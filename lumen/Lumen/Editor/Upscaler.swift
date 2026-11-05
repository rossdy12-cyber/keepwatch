import Foundation

/// The Lumen AI upscaler running on your TrueNAS (the lumen-ai app). Its logs show the address and key.
struct UpscalerSettings: Codable, Equatable {
    var address = "http://100.85.127.42:10702"
    var key = ""

    var isConfigured: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty && base != nil }

    var base: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    static func load() -> UpscalerSettings { Keychain.load(UpscalerSettings.self, for: "upscaler") ?? UpscalerSettings() }
    func save() { Keychain.save(self, for: "upscaler") }
}

enum UpscaleError: LocalizedError {
    case notSetUp, server(String), unreachable(String)
    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Add your NAS's upscaler address and key first."
        case .server(let message): return message
        case .unreachable(let detail): return "Couldn't reach the upscaler on your NAS (\(detail)). For a 100.x address, check Tailscale is on."
        }
    }
}

/// Sends a photo to the NAS, follows the job, and downloads the result.
struct UpscaleClient {
    let settings: UpscalerSettings
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard settings.isConfigured, let base = settings.base,
              var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw UpscaleError.notSetUp
        }
        components.queryItems = [URLQueryItem(name: "token", value: settings.key.trimmingCharacters(in: .whitespaces))] + query
        guard let url = components.url else { throw UpscaleError.notSetUp }
        return url
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 { throw UpscaleError.server("The upscaler didn't accept the key. Copy it again from the lumen-ai app's logs.") }
            return (data, status)
        } catch let error as UpscaleError {
            throw error
        } catch {
            throw UpscaleError.unreachable(error.localizedDescription)
        }
    }

    /// The largest photo (in megapixels) the NAS will work on at this scale; bigger ones it shrinks first.
    func inputLimit(scale: Int) async -> Double {
        guard let request = try? URLRequest(url: url("limits")),
              let response = try? await fetch(request), response.1 == 200,
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let limits = json["maxInputMegapixels"] as? [String: Double] else {
            return scale == 4 ? 1 : 4
        }
        return limits[String(scale)] ?? (scale == 4 ? 1 : 4)
    }

    /// Sends the photo and a mask (white = remove) to the NAS for AI object removal.
    /// Body is: 4-byte big-endian image length, then the image JPEG, then the mask PNG.
    func startInpaint(image: Data, mask: Data) async throws -> String {
        var body = Data()
        var length = UInt32(image.count).bigEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(image)
        body.append(mask)
        var request = URLRequest(url: try url("inpaint"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, status) = try await fetch(request)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = json["job"] as? String else {
            throw UpscaleError.server(Self.errorText(data) ?? "The NAS refused the removal (HTTP \(status)).")
        }
        return job
    }

    /// Sends a set of overlapping frames to the NAS to stitch into a panorama.
    /// Body is: 4-byte big-endian frame count, then for each frame a 4-byte big-endian length followed by its JPEG.
    func startPano(images: [Data]) async throws -> String {
        var body = Data()
        var count = UInt32(images.count).bigEndian
        withUnsafeBytes(of: &count) { body.append(contentsOf: $0) }
        for image in images {
            var length = UInt32(image.count).bigEndian
            withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
            body.append(image)
        }
        var request = URLRequest(url: try url("pano"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, status) = try await fetch(request)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = json["job"] as? String else {
            throw UpscaleError.server(Self.errorText(data) ?? "The NAS refused the panorama (HTTP \(status)).")
        }
        return job
    }

    func start(jpeg: Data, scale: Int) async throws -> String {
        var request = URLRequest(url: try url("upscale", [URLQueryItem(name: "scale", value: String(scale))]))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (data, status) = try await fetch(request)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = json["job"] as? String else {
            throw UpscaleError.server(Self.errorText(data) ?? "The upscaler refused the photo (HTTP \(status)).")
        }
        return job
    }

    struct Status {
        var state: String
        var progress: Double
        var queuePosition: Int
        var error: String?
        /// "GPU (DESKTOP-ABC)" or "NAS processor".
        var processor: String?
    }

    func status(_ job: String) async throws -> Status {
        let (data, status) = try await fetch(URLRequest(url: try url("jobs/\(job)")))
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpscaleError.server(Self.errorText(data) ?? "Lost track of the upscale job.")
        }
        return Status(state: json["status"] as? String ?? "unknown", progress: json["progress"] as? Double ?? 0,
                      queuePosition: json["queuePosition"] as? Int ?? 0, error: json["error"] as? String,
                      processor: json["processor"] as? String)
    }

    func result(_ job: String) async throws -> Data {
        let (data, status) = try await fetch(URLRequest(url: try url("jobs/\(job)/result")))
        guard status == 200, !data.isEmpty else { throw UpscaleError.server("Couldn't download the upscaled photo.") }
        return data
    }

    private static func errorText(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}
