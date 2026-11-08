import Foundation

/// One thing Jarvis remembers about you.
struct MemoryFact: Codable, Identifiable, Equatable {
    let id: Int
    let text: String
    let source: String     // "manual", "auto", "import", "distill"
    let pinned: Bool
}

/// A document in Jarvis's knowledge base (it's searched to answer questions).
struct KnowledgeDoc: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let source: String
    let chunks: Int
}

/// The jarvis-core `/health` summary.
struct CoreStats: Codable, Equatable {
    let model: String
    let configured: Bool
    let facts: Int
    let knowledgeChunks: Int
    let embeddings: Bool

    enum CodingKeys: String, CodingKey {
        case model, configured, facts, embeddings
        case knowledgeChunks = "knowledge_chunks"
    }
}

/// The memory API of the new jarvis-core. These endpoints only exist on that core; other servers return 404,
/// which the Memory screen treats as "memory not available here".
extension JarvisClient {
    private func sendDecoding<T: Decodable>(_ path: String, method: String = "GET", json: Any? = nil,
                                            as type: T.Type) async throws -> T {
        let request = try makeRequest(path, method: method, json: json, timeout: 30)
        let (data, response) = try await httpSession.data(for: request)
        try Self.check(response, body: data, path: path)
        if Self.isHTML(response, data) { throw JarvisError.webPage }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String, json: Any? = nil) async throws {
        let request = try makeRequest(path, method: method, json: json, timeout: 30)
        let (data, response) = try await httpSession.data(for: request)
        try Self.check(response, body: data, path: path)
    }

    func coreStats() async throws -> CoreStats {
        try await sendDecoding("/health", as: CoreStats.self)
    }

    func fetchFacts() async throws -> [MemoryFact] {
        try await sendDecoding("/api/memory/facts", as: [MemoryFact].self)
    }

    func addFact(_ text: String, pinned: Bool) async throws {
        try await send("/api/memory/facts", method: "POST", json: ["text": text, "pinned": pinned])
    }

    func deleteFact(_ id: Int) async throws {
        try await send("/api/memory/facts/\(id)", method: "DELETE")
    }

    func pinFact(_ id: Int, pinned: Bool) async throws {
        try await send("/api/memory/facts/\(id)/pin", method: "POST", json: ["pinned": pinned])
    }

    func fetchKnowledge() async throws -> [KnowledgeDoc] {
        try await sendDecoding("/api/knowledge", as: [KnowledgeDoc].self)
    }

    func addKnowledge(title: String, text: String) async throws {
        try await send("/api/knowledge", method: "POST", json: ["title": title, "text": text])
    }

    func deleteKnowledge(_ id: Int) async throws {
        try await send("/api/knowledge/\(id)", method: "DELETE")
    }

    func importMemory(title: String, text: String, kind: String) async throws {
        try await send("/api/memory/import", method: "POST", json: ["title": title, "text": text, "kind": kind])
    }
}
