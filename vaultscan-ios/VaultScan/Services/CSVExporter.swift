import Foundation

enum CSVExporter {
    static func csv(for documents: [ScannedDocument]) -> String {
        var rows: [[String]] = [
            [
                "Title",
                "Category",
                "Supplier",
                "Date",
                "Amount",
                "Notes",
                "Tags",
                "OCR text",
                "Upload state",
                "Remote path"
            ]
        ]

        let formatter = ISO8601DateFormatter()

        for document in documents {
            rows.append([
                document.title,
                document.category,
                document.supplier,
                formatter.string(from: document.documentDate),
                document.amount,
                document.notes,
                document.tags.joined(separator: "; "),
                document.ocrText,
                document.uploadState.rawValue,
                document.remotePath
            ])
        }

        return rows
            .map(escapedRow)
            .joined(separator: "\n")
    }

    private static func escapedRow(_ values: [String]) -> String {
        values
            .map { value in
                let escaped = value
                    .replacingOccurrences(of: "\"", with: "\"\"")

                return "\"\(escaped)\""
            }
            .joined(separator: ",")
    }
}
