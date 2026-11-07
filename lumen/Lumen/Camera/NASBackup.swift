import Foundation
import Photos

/// Copies the original files of new photos and videos to the lumen-ai app on your NAS (when turned on).
/// Files wait in a folder on the iPhone until the NAS has them, so nothing is lost while you're away from home.
final class NASBackup {
    static let shared = NASBackup()

    private let queue = DispatchQueue(label: "lumen.backup")
    private var uploading = false
    private var retryScheduled = false
    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NASBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    var isOn: Bool { Prefs.bool("nasBackup", false) }

    /// How many files are still waiting for the NAS.
    var pendingCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.count) ?? 0
    }

    func add(resources: [(PHAssetResourceType, Data)], pairedVideo: URL?) {
        guard isOn else { return }
        let stamp = Self.stamp()
        let id = UUID().uuidString.prefix(6)
        // Copied straight away: the camera deletes its temporary files once Photos has them.
        if let pairedVideo {
            try? FileManager.default.copyItem(at: pairedVideo, to: folder.appendingPathComponent("\(stamp) \(id).mov"))
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
        guard isOn else { return }
        let name = "\(Self.stamp()) \(UUID().uuidString.prefix(6)).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        kick()
    }

    /// Tries the waiting files again (app start, setting turned on).
    func kick() {
        queue.async { self.uploadNext() }
    }

    private func uploadNext() {
        guard isOn, !uploading else { return }
        let settings = UpscalerSettings.load()
        guard settings.isConfigured, let base = settings.base,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter({ !$0.lastPathComponent.hasPrefix(".") })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let file = files.first else { return }
        var components = URLComponents(url: base.appendingPathComponent("backup"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: settings.key.trimmingCharacters(in: .whitespaces)),
                                  URLQueryItem(name: "name", value: file.lastPathComponent)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploading = true
        session.uploadTask(with: request, fromFile: file) { _, response, error in
            self.queue.async {
                self.uploading = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil && status == 200 {
                    try? FileManager.default.removeItem(at: file)
                    self.uploadNext()
                } else {
                    // The NAS isn't reachable (or refused): try again in a minute.
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
