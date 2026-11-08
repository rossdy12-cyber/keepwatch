import SwiftUI

/// Shows and edits what Jarvis remembers: the facts it always knows and its searchable knowledge base.
/// Works with the new jarvis-core; other servers show a gentle "not available here" note.
struct MemoryView: View {
    @EnvironmentObject private var settings: JarvisSettings
    @StateObject private var store = MemoryStore()

    @State private var showAddFact = false
    @State private var showAddDoc = false

    var body: some View {
        NavigationStack {
            Group {
                if !store.available {
                    unavailable
                } else {
                    list
                }
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if store.loading || store.busy { ProgressView() }
                }
            }
            .task(id: settings.config.address) { await store.load(settings.client) }
            .refreshable { await store.load(settings.client) }
            .sheet(isPresented: $showAddFact) {
                AddFactSheet { text, pinned in
                    Task { await store.addFact(text, pinned: pinned, client: settings.client) }
                }
            }
            .sheet(isPresented: $showAddDoc) {
                AddDocSheet { title, text in
                    Task { await store.addKnowledge(title: title, text: text, client: settings.client) }
                }
            }
        }
    }

    private var list: some View {
        List {
            if let stats = store.stats {
                Section {
                    LabeledContent("Model", value: stats.model)
                    LabeledContent("Facts", value: "\(stats.facts)")
                    LabeledContent("Knowledge chunks", value: "\(stats.knowledgeChunks)")
                    LabeledContent("Search", value: stats.embeddings ? "Semantic" : "Keyword")
                    if !stats.configured {
                        Label("No API key set on the core yet.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                } header: { Text("Jarvis core") }
            }

            if let error = store.error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(Theme.warning)
                }
            }

            Section {
                if store.facts.isEmpty {
                    Text("Nothing yet. Add a fact, or just chat — Jarvis learns as you go.")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(store.facts) { fact in
                    FactRow(fact: fact)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await store.deleteFact(fact, client: settings.client) }
                            } label: { Label("Forget", systemImage: "trash") }
                            Button {
                                Task { await store.setPinned(fact, pinned: !fact.pinned, client: settings.client) }
                            } label: { Label(fact.pinned ? "Unpin" : "Pin", systemImage: fact.pinned ? "pin.slash" : "pin") }
                            .tint(Theme.accent)
                        }
                }
                Button {
                    showAddFact = true
                } label: { Label("Add a fact", systemImage: "plus") }
            } header: {
                Text("What Jarvis knows")
            } footer: {
                Text("Pinned facts are always kept in mind. Swipe a fact to pin or forget it.")
            }

            Section {
                if store.docs.isEmpty {
                    Text("No documents. Add notes or a manual for Jarvis to look things up in.")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(store.docs) { doc in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title.isEmpty ? "Untitled" : doc.title)
                            Text("\(doc.chunks) chunk\(doc.chunks == 1 ? "" : "s")\(doc.source == "import" ? " · imported" : "")")
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await store.deleteKnowledge(doc, client: settings.client) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                Button {
                    showAddDoc = true
                } label: { Label("Add a document", systemImage: "plus") }
            } header: {
                Text("Knowledge base")
            } footer: {
                Text("Jarvis searches these when answering. Great for manuals, notes and reference info.")
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundStyle(Theme.secondaryText)
            Text("Memory isn't available here")
                .font(.headline)
            Text(store.error ?? "Point Jarvis at your jarvis-core (the memory-backed core) in Settings, then pull to refresh.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Refresh") { Task { await store.load(settings.client) } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(fact.pinned ? Theme.accent : Theme.secondaryText)
                .frame(width: 22)
            Text(fact.text)
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        if fact.pinned { return "pin.fill" }
        switch fact.source {
        case "auto": return "sparkles"
        case "import": return "tray.and.arrow.down"
        case "distill": return "wand.and.stars"
        default: return "note.text"
        }
    }
}

private struct AddFactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pinned = false
    let onSave: (String, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Something Jarvis should remember…", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("Pin (always keep in mind)", isOn: $pinned)
                } footer: {
                    Text("For example: \u{201C}My dog is called Nimbus\u{201D} or \u{201C}The bins go out on Tuesday\u{201D}.")
                }
            }
            .navigationTitle("Add fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSave(trimmed, pinned) }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct AddDocSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    let onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Boiler manual", text: $title)
                }
                Section("Content") {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                }
            }
            .navigationTitle("Add document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty { onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), body) }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
