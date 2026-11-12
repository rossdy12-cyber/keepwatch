import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.bookmarks.isEmpty {
                    Text("No bookmarks yet").foregroundStyle(Crimson.muted)
                        .listRowBackground(Crimson.panel)
                }
                ForEach(store.bookmarks) { b in
                    Button { store.current?.load(b.url); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title.isEmpty ? b.url : b.title).foregroundStyle(Crimson.text).lineLimit(1)
                            Text(b.url).font(.caption).foregroundStyle(Crimson.muted).lineLimit(1)
                        }
                    }
                    .listRowBackground(Crimson.panel)
                }
                .onDelete { store.bookmarks.remove(atOffsets: $0) }
            }
            .scrollContentBackground(.hidden)
            .background(Crimson.bg.ignoresSafeArea())
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
        .tint(Crimson.accent)
    }
}
