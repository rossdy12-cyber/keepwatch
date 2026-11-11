import SwiftUI

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var updated: Date = Date()
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] { didSet { persist() } }
    private let key = "notes.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: "notes.v1"),
           let n = try? JSONDecoder().decode([Note].self, from: d) {
            notes = n
        } else {
            notes = [Note(title: "A first inscription", body: "Tap to write. Your words are kept on this device alone.")]
        }
    }
    func add() -> Note { let n = Note(title: "Untitled", body: ""); notes.insert(n, at: 0); return n }
    func update(_ n: Note) {
        if let i = notes.firstIndex(where: { $0.id == n.id }) { var m = n; m.updated = Date(); notes[i] = m }
    }
    func delete(_ n: Note) { notes.removeAll { $0.id == n.id } }
    private func persist() {
        if let d = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(d, forKey: key) }
    }
}

struct NotesView: View {
    @EnvironmentObject var store: Store
    @StateObject private var notes = NotesStore()
    @State private var editing: Note?
    private var theme: GothicTheme { store.theme }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                GothicTitle(text: "Grimoire", theme: theme, size: 26)
                Spacer()
                Button { editing = notes.add() } label: {
                    Image(systemName: "plus").font(.title3).foregroundStyle(theme.accentColor)
                }
            }
            .padding(.horizontal, 20).padding(.top, 50)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(notes.notes) { note in
                        GothicCard(theme: theme) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                    .font(.system(size: 17, weight: .semibold, design: .serif))
                                    .foregroundStyle(theme.textColor)
                                Text(note.body).font(.subheadline).foregroundStyle(theme.mutedColor)
                                    .lineLimit(2)
                                Text(note.updated, format: .dateTime.day().month().hour().minute())
                                    .font(.caption2).foregroundStyle(theme.mutedColor.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onTapGesture { editing = note }
                        .contextMenu {
                            Button(role: .destructive) { notes.delete(note) } label: { Label("Burn", systemImage: "flame") }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .sheet(item: $editing) { note in
            NoteEditor(note: note, theme: theme) { notes.update($0) }
        }
    }
}

struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var note: Note
    let theme: GothicTheme
    let onSave: (Note) -> Void

    var body: some View {
        ZStack {
            GothicBackground(theme: theme)
            VStack(spacing: 12) {
                TextField("Title", text: $note.title)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(theme.textColor)
                Filigree(theme: theme)
                TextEditor(text: $note.body)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(theme.textColor)
                    .scrollContentBackground(.hidden)
                    .background(theme.panelColor.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { onSave(note); dismiss() }
                .font(.headline).foregroundStyle(theme.accentColor)
                .padding(20)
        }
    }
}
