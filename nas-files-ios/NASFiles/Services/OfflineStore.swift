import Foundation

struct OfflineFile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var remotePath: String
    var localFileName: String
    var size: Int64
    var downloadedAt: Date?
    var state: DownloadState
    var progress: Double
    var retryCount: Int
    var nextRetryAt: Date?
    var lastError: String?

    init(file: RemoteFile) {
        id = file.path
        name = file.name
        remotePath = file.path
        localFileName = "\(UUID().uuidString)-\(file.name)"
        size = file.size
        state = .pending
        progress = 0
        retryCount = 0
    }
}

enum DownloadState: String, Codable {
    case pending
    case downloading
    case downloaded
    case failed

    var displayTitle: String {
        switch self {
        case .pending: return "Pending"
        case .downloading: return "Downloading"
        case .downloaded: return "Available offline"
        case .failed: return "Failed"
        }
    }
}

@MainActor
final class OfflineStore: ObservableObject {
    @Published private(set) var files: [OfflineFile] = []
    @Published private(set) var pinnedPaths: [String] = []

    private var offlineDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("OfflineFiles", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var storeURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline-files.json")
    }

    private var pinnedURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pinned-paths.json")
    }

    init() {
        load()
    }

    func isDownloaded(_ file: RemoteFile) -> Bool {
        files.contains { $0.id == file.path && $0.state == .downloaded }
    }

    func isPinned(_ path: String) -> Bool {
        pinnedPaths.contains(path)
    }

    func localURL(for file: RemoteFile) -> URL? {
        guard let record = files.first(where: { $0.id == file.path }) else {
            return nil
        }

        return offlineDirectory.appendingPathComponent(record.localFileName)
    }

    func record(for file: RemoteFile) -> OfflineFile? {
        files.first { $0.id == file.path }
    }

    func createRecord(for file: RemoteFile) -> OfflineFile {
        if let existing = record(for: file) {
            return existing
        }

        let newRecord = OfflineFile(file: file)
        files.append(newRecord)
        save()

        return newRecord
    }

    func update(_ record: OfflineFile) {
        if let index = files.firstIndex(where: { $0.id == record.id }) {
            files[index] = record
        } else {
            files.append(record)
        }

        save()
    }

    func remove(_ file: RemoteFile) {
        guard let record = record(for: file) else {
            return
        }

        let localURL = offlineDirectory.appendingPathComponent(record.localFileName)
        try? FileManager.default.removeItem(at: localURL)

        files.removeAll { $0.id == record.id }
        save()
    }

    func togglePin(_ path: String) {
        if pinnedPaths.contains(path) {
            pinnedPaths.removeAll { $0 == path }
        } else {
            pinnedPaths.append(path)
        }

        savePins()
    }

    var storageUsage: Int64 {
        files.reduce(0) { total, file in
            let url = offlineDirectory.appendingPathComponent(file.localFileName)
            var size: Int64 = 0

            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attributes[.size] as? Int64 {
                size = fileSize
            }

            return total + size
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([OfflineFile].self, from: data) {
            files = decoded
        }

        if let data = try? Data(contentsOf: pinnedURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            pinnedPaths = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(files) else {
            return
        }

        try? data.write(to: storeURL, options: .atomic)
    }

    private func savePins() {
        guard let data = try? JSONEncoder().encode(pinnedPaths) else {
            return
        }

        try? data.write(to: pinnedURL, options: .atomic)
    }
}
