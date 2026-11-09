import Foundation

enum VSUploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed

    var displayTitle: String {
        switch self {
        case .pending: return "Pending upload"
        case .uploading: return "Uploading"
        case .uploaded: return "Uploaded"
        case .failed: return "Upload failed"
        }
    }
}

struct VSScannedDocument: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var category: String
    var supplier: String
    var documentDate: Date
    var amount: String
    var notes: String
    var ocrText: String
    var pdfFileName: String
    var uploadState: VSUploadState
    var remotePath: String
    var createdAt: Date
    var lastUploadError: String?
    var tags: [String]
    var uploadProgress: Double
    var retryCount: Int
    var nextRetryAt: Date?
    var uploadedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        category: String = "Receipt",
        supplier: String = "",
        documentDate: Date = Date(),
        amount: String = "",
        notes: String = "",
        ocrText: String = "",
        pdfFileName: String,
        uploadState: VSUploadState = .pending,
        remotePath: String = "",
        createdAt: Date = Date(),
        lastUploadError: String? = nil,
        tags: [String] = [],
        uploadProgress: Double = 0,
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        uploadedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.supplier = supplier
        self.documentDate = documentDate
        self.amount = amount
        self.notes = notes
        self.ocrText = ocrText
        self.pdfFileName = pdfFileName
        self.uploadState = uploadState
        self.remotePath = remotePath
        self.createdAt = createdAt
        self.lastUploadError = lastUploadError
        self.tags = tags
        self.uploadProgress = uploadProgress
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.uploadedAt = uploadedAt
    }

    var searchableText: String {
        [
            title,
            category,
            supplier,
            amount,
            notes,
            ocrText,
            tags.joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()
    }
}
