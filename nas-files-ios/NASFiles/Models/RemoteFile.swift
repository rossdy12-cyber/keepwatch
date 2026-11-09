import Foundation

struct RemoteFile: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    let contentType: String?

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isPreviewable: Bool {
        guard !isDirectory else { return false }

        let previewable = [
            "pdf", "png", "jpg", "jpeg", "heic", "heif", "gif",
            "mp4", "mov", "m4v", "mp3", "m4a", "wav", "txt", "md",
            "csv", "json", "xml", "doc", "docx", "xls", "xlsx",
            "ppt", "pptx", "pages", "numbers", "key"
        ]

        return previewable.contains(fileExtension)
    }

    var systemImage: String {
        if isDirectory {
            return "folder"
        }

        switch fileExtension {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "heif", "gif": return "photo"
        case "mp4", "mov", "m4v": return "video"
        case "mp3", "m4a", "wav": return "music.note"
        case "zip", "rar", "7z": return "doc.zipper"
        default: return "doc"
        }
    }

    var formattedSize: String {
        guard !isDirectory, size > 0 else { return "" }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
