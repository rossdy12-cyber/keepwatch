import Foundation

struct Photo: Identifiable, Codable, Hashable {
    let uid: String
    let fileName: String?
    let title: String?

    var id: String { uid }

    enum CodingKeys: String, CodingKey {
        case uid = "UID"
        case fileName = "FileName"
        case title = "Title"
    }
}

struct PhotoSearchResponse: Codable {
    let models: [Photo]
    let count: Int?
    let offset: Int?

    enum CodingKeys: String, CodingKey {
        case models
        case count
        case offset
    }
}
