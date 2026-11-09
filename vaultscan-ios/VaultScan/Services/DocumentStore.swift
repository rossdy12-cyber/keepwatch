import Foundation

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [ScannedDocument] = []

    private let queueFileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        queueFileURL = directory.appendingPathComponent("vaultscan-documents.json")
        load()
    }

    func add(_ document: ScannedDocument) {
        documents.insert(document, at: 0)
        save()
    }

    func update(_ document: ScannedDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else {
            return
        }

        documents[index] = document
        save()
    }

    func delete(_ document: ScannedDocument) {
        documents.removeAll { $0.id == document.id }
        save()

        let fileURL = localPDFURL(for: document)

        try? FileManager.default.removeItem(at: fileURL)
    }

    func localPDFURL(for document: ScannedDocument) -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent(document.pdfFileName)
    }

    func pendingDocuments() -> [ScannedDocument] {
        documents.filter { $0.uploadState == .pending || $0.uploadState == .failed }
    }

    private func load() {
        guard let data = try? Data(contentsOf: queueFileURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let decoded = try? decoder.decode([ScannedDocument].self, from: data) {
            documents = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(documents) else {
            return
        }

        try? data.write(to: queueFileURL, options: .atomic)
    }
}
