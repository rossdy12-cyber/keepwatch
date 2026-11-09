import Foundation

struct PVPhoto: Identifiable, Codable, Hashable {
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

struct PVPhotoSearchResponse: Codable {
    let models: [PVPhoto]
    let count: Int?
    let offset: Int?

    enum CodingKeys: String, CodingKey {
        case models
        case count
        case offset
    }
}
