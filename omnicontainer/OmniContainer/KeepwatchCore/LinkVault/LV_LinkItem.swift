import Foundation

struct LVLinkItem: Identifiable, Codable, Hashable {
    var id: UUID
    var url: String
    var title: String
    var pageDescription: String
    var notes: String
    var tags: [String]
    var isFavourite: Bool
    var isRead: Bool
    var createdAt: Date
    var readAt: Date?
    var faviconURL: String?
    var canonicalURL: String?
    var siteName: String?
    var isArchived: Bool
    var articleText: String?
    var snapshotAt: Date?

    init(id: UUID = UUID(), url: String, title: String = "", pageDescription: String = "", notes: String = "", tags: [String] = [], isFavourite: Bool = false, isRead: Bool = false, createdAt: Date = Date(), readAt: Date? = nil, faviconURL: String? = nil, canonicalURL: String? = nil, siteName: String? = nil, isArchived: Bool = false, articleText: String? = nil, snapshotAt: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.pageDescription = pageDescription
        self.notes = notes
        self.tags = tags
        self.isFavourite = isFavourite
        self.isRead = isRead
        self.createdAt = createdAt
        self.readAt = readAt
        self.faviconURL = faviconURL
        self.canonicalURL = canonicalURL
        self.siteName = siteName
        self.isArchived = isArchived
        self.articleText = articleText
        self.snapshotAt = snapshotAt
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, pageDescription, notes, tags, isFavourite, isRead, createdAt, readAt
        case faviconURL, canonicalURL, siteName, isArchived, articleText, snapshotAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        pageDescription = try c.decode(String.self, forKey: .pageDescription)
        notes = try c.decode(String.self, forKey: .notes)
        tags = try c.decode([String].self, forKey: .tags)
        isFavourite = try c.decode(Bool.self, forKey: .isFavourite)
        isRead = try c.decode(Bool.self, forKey: .isRead)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        faviconURL = try c.decodeIfPresent(String.self, forKey: .faviconURL)
        canonicalURL = try c.decodeIfPresent(String.self, forKey: .canonicalURL)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        articleText = try c.decodeIfPresent(String.self, forKey: .articleText)
        snapshotAt = try c.decodeIfPresent(Date.self, forKey: .snapshotAt)
    }

    var displayTitle: String { title.isEmpty ? displayHost : title }
    var displayHost: String { URL(string: url)?.host ?? url }
    var searchableText: String {
        [title, url, pageDescription, notes, tags.joined(separator: " "), articleText ?? ""].joined(separator: " ").lowercased()
    }
}
