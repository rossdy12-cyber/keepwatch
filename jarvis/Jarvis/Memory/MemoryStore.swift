import Foundation

/// Loads and edits what Jarvis remembers (facts + knowledge base) via the jarvis-core memory API.
@MainActor
final class MemoryStore: ObservableObject {
    @Published var stats: CoreStats?
    @Published var facts: [MemoryFact] = []
    @Published var docs: [KnowledgeDoc] = []
    @Published var loading = false
    @Published var busy = false
    @Published var error: String?
    /// False when the server has no memory API (not the new jarvis-core).
    @Published var available = true

    func load(_ client: JarvisClient) async {
        loading = true
        error = nil
        do {
            let facts = try await client.fetchFacts()
            let docs = try await client.fetchKnowledge()
            self.facts = facts
            self.docs = docs
            self.stats = try? await client.coreStats()
            available = true
        } catch JarvisError.notFound {
            available = false
            error = "This server has no Jarvis memory. Point Jarvis at your jarvis-core (Settings), then try again."
        } catch JarvisError.notConfigured {
            available = false
            error = "Set your Jarvis address in Settings first."
        } catch {
            self.error = describe(error)
        }
        loading = false
    }

    func addFact(_ text: String, pinned: Bool, client: JarvisClient) async {
        await perform(client) { try await client.addFact(text, pinned: pinned) }
    }

    func deleteFact(_ fact: MemoryFact, client: JarvisClient) async {
        facts.removeAll { $0.id == fact.id }
        await perform(client, reload: false) { try await client.deleteFact(fact.id) }
    }

    func setPinned(_ fact: MemoryFact, pinned: Bool, client: JarvisClient) async {
        await perform(client) { try await client.pinFact(fact.id, pinned: pinned) }
    }

    func addKnowledge(title: String, text: String, client: JarvisClient) async {
        await perform(client) { try await client.addKnowledge(title: title, text: text) }
    }

    func deleteKnowledge(_ doc: KnowledgeDoc, client: JarvisClient) async {
        docs.removeAll { $0.id == doc.id }
        await perform(client, reload: false) { try await client.deleteKnowledge(doc.id) }
    }

    private func perform(_ client: JarvisClient, reload: Bool = true, _ action: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        do {
            try await action()
            if reload {
                facts = (try? await client.fetchFacts()) ?? facts
                docs = (try? await client.fetchKnowledge()) ?? docs
                stats = try? await client.coreStats()
            }
        } catch {
            self.error = describe(error)
        }
        busy = false
    }
}
