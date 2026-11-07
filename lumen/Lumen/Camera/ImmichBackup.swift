import Foundation
import Photos

/// Uploads new photos and videos straight to your Immich server (so they don't fill up the iPhone).
/// Files wait in a folder on the iPhone until Immich has them, so nothing is lost while you're away from home.
final class ImmichBackup {
    static let shared = ImmichBackup()

    private let queue = DispatchQueue(label: "lumen.immich")
    private var uploading = false
    private var retryScheduled = false
    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("ImmichBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    var isConfigured: Bool { ImmichSettings.load().isConfigured }

    /// How many files are still waiting to reach Immich.
    var pendingCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.count) ?? 0
    }

    func add(resources: [(PHAssetResourceType, Data)], pairedVideo: URL?) {
        let stamp = Self.stamp()
        let id = UUID().uuidString.prefix(6)
        // The paired video of a Live Photo: copied straight away before the camera's temp file goes.
        if let pairedVideo {
            let dest = folder.appendingPathComponent("\(stamp) \(id).mov")
            try? FileManager.default.copyItem(at: pairedVideo, to: dest)
        }
        queue.async {
            for (index, resource) in resources.enumerated() {
                let name = "\(stamp) \(id)\(index == 0 ? "" : "-\(index)").\(Self.fileExtension(resource.1))"
                try? resource.1.write(to: self.folder.appendingPathComponent(name))
            }
            self.uploadNext()
        }
    }

    func add(video url: URL) {
        let name = "\(Self.stamp()) \(UUID().uuidString.prefix(6)).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        kick()
    }

    /// Tries the waiting files again (app start, Immich just set up, "upload now").
    func kick() {
        queue.async { self.uploadNext() }
    }

    private func uploadNext() {
        guard !uploading else { return }
        let settings = ImmichSettings.load()
        guard settings.isConfigured, let base = settings.base,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter({ !$0.lastPathComponent.hasPrefix(".") })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let file = files.first else { return }

        guard let bodyFile = Self.makeMultipartBody(file: file) else {
            // Couldn't build the body (e.g. the file vanished): drop it so the queue isn't stuck.
            try? FileManager.default.removeItem(at: file)
            queue.async { self.uploadNext() }
            return
        }
        var request = URLRequest(url: base.appendingPathComponent("assets"))
        request.httpMethod = "POST"
        request.setValue(settings.key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(Self.boundary)", forHTTPHeaderField: "Content-Type")
        uploading = true
        session.uploadTask(with: request, fromFile: bodyFile) { _, response, error in
            try? FileManager.default.removeItem(at: bodyFile)
            self.queue.async {
                self.uploading = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil && (200...299).contains(status) {
                    // Uploaded (or Immich already had it): it's safe to drop from the phone now.
                    try? FileManager.default.removeItem(at: file)
                    self.uploadNext()
                } else {
                    // Immich isn't reachable (or refused): try again in a minute.
                    guard !self.retryScheduled else { return }
                    self.retryScheduled = true
                    self.queue.asyncAfter(deadline: .now() + 60) {
                        self.retryScheduled = false
                        self.uploadNext()
                    }
                }
            }
        }.resume()
    }

    // MARK: Multipart body

    static let boundary = "----lumen-immich-boundary"

    /// Writes a multipart/form-data body (the asset file plus Immich's required fields) to a temp file,
    /// streaming the asset in so a big RAW/video isn't held in memory. Returns the temp file URL.
    private static func makeMultipartBody(file: URL) -> URL? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int, size > 0 else { return nil }
        let created = (attrs[.modificationDate] as? Date) ?? (attrs[.creationDate] as? Date) ?? Date()
        let iso = ISO8601DateFormatter().string(from: created)
        let name = file.lastPathComponent

        let fields: [(String, String)] = [
            ("deviceAssetId", name),            // stable per file, so a retry dedups instead of duplicating
            ("deviceId", "Lumen"),
            ("fileCreatedAt", iso),
            ("fileModifiedAt", iso)
        ]
        var preamble = ""
        for (key, value) in fields {
            preamble += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
        }
        preamble += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(name)\"\r\n"
        preamble += "Content-Type: \(mimeType(name))\r\n\r\n"
        let closing = "\r\n--\(boundary)--\r\n"

        let bodyURL = fm.temporaryDirectory.appendingPathComponent("immich-\(UUID().uuidString)")
        guard fm.createFile(atPath: bodyURL.path, contents: Data(preamble.utf8)),
              let handle = try? FileHandle(forWritingTo: bodyURL),
              let input = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close(); try? input.close() }
        do {
            try handle.seekToEnd()
            while true {
                let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data(closing.utf8))
        } catch {
            try? fm.removeItem(at: bodyURL)
            return nil
        }
        return bodyURL
    }

    private static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic", "heif": return "image/heic"
        case "png": return "image/png"
        case "dng": return "image/x-adobe-dng"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func fileExtension(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if head.starts(with: [0x49, 0x49, 0x2A, 0x00]) || head.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "dng" }
        return "heic"
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }
}
