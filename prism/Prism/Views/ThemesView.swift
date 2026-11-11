import SwiftUI

struct ThemesView: View {
    @EnvironmentObject var store: ThemeStore
    @State private var editing: ThemeSpec?

    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(store.themes) { theme in
                        ThemeCard(theme: theme, selected: theme.id == store.selectedID)
                            .onTapGesture { store.select(theme) }
                            .contextMenu {
                                Button { editing = theme } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                                Button { editing = store.duplicate(theme) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                if store.themes.count > 1 {
                                    Button(role: .destructive) { store.delete(theme) } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                    }
                }
                .padding()
            }
            .navigationTitle("Themes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let fresh = ThemeSpec(name: "My Theme", colors: ["5B247A", "1BCEDF"], accent: "FFFFFF", style: .gradient)
                        store.update(fresh)
                        editing = fresh
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { spec in
                EditorView(spec: spec)
            }
        }
    }
}

struct ThemeCard: View {
    let theme: ThemeSpec
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeBackground(spec: theme)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, theme.accentColor)
                            .font(.title3)
                            .padding(8)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(selected ? theme.accentColor : .white.opacity(0.08), lineWidth: selected ? 2.5 : 1)
                )
            HStack {
                Text(theme.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(theme.style.label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
