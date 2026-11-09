import Foundation

enum MPDownloadState: String, Codable, CaseIterable {
    case pending
    case downloading
    case completed
    case error

    var displayTitle: String {
        switch self {
        case .pending: return "Pending"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .error: return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}

struct MPDownloadJob: Identifiable, Codable, Hashable {
    var id: UUID
    var url: String
    var title: String
    var outputType: MPOutputType
    var quality: String
    var destination: String
    var state: MPDownloadState
    var createdAt: Date
    var errorMessage: String?
    var progress: Double?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speed: String?
    var eta: String?
    var thumbnailURL: String?
    var lastEvent: String?
    var lastEventAt: Date?

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        outputType: MPOutputType,
        quality: String,
        destination: String,
        state: MPDownloadState = .pending,
        createdAt: Date = Date(),
        errorMessage: String? = nil,
        progress: Double? = nil,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        speed: String? = nil,
        eta: String? = nil,
        thumbnailURL: String? = nil,
        lastEvent: String? = nil,
        lastEventAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.outputType = outputType
        self.quality = quality
        self.destination = destination
        self.state = state
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.eta = eta
        self.thumbnailURL = thumbnailURL
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
    }
}

enum MPOutputType: String, Codable, CaseIterable, Identifiable {
    case video
    case audio

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        }
    }
}
