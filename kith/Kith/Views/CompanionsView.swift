import SwiftUI

struct CompanionsView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var draft: EditingDraft?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if store.companions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.companions) { companion in
                                NavigationLink { ChatView(companion: companion) } label: { CompanionCard(companion: companion) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { draft = EditingDraft(companion: companion, isNew: false) } label: { Label("Edit", systemImage: "pencil") }
                                        Button(role: .destructive) { store.delete(companion) } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Kith")
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { draft = EditingDraft(companion: Companion(), isNew: true) } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $draft) { d in CustomizeView(companion: d.companion, isNew: d.isNew) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            CreatureView(style: CreatureStyle())
                .frame(width: 160, height: 160)
            Text("Meet your Kith").font(.title2.weight(.semibold))
            Text("Design a little companion — how it looks and who it is — then chat and it gets to know you.")
                .font(.subheadline).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center).padding(.horizontal, 36)
            Button { draft = EditingDraft(companion: Companion(), isNew: true) } label: {
                Label("Create a companion", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct EditingDraft: Identifiable {
    let id = UUID()
    var companion: Companion
    var isNew: Bool
}

private struct CompanionCard: View {
    let companion: Companion

    var body: some View {
        VStack(spacing: 8) {
            CreatureView(style: companion.style)
                .frame(height: 110)
            Text(companion.name).font(.headline).lineLimit(1)
            Text(companion.role.label).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
