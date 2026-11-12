import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.history.isEmpty {
                    Text("No history").foregroundStyle(Crimson.muted)
                        .listRowBackground(Crimson.panel)
                }
                ForEach(store.history) { h in
                    Button { store.current?.load(h.url); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.title.isEmpty ? h.url : h.title).foregroundStyle(Crimson.text).lineLimit(1)
                            Text(h.url).font(.caption).foregroundStyle(Crimson.muted).lineLimit(1)
                        }
                    }
                    .listRowBackground(Crimson.panel)
                }
                .onDelete { store.history.remove(atOffsets: $0) }
            }
            .scrollContentBackground(.hidden)
            .background(Crimson.bg.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { store.clearHistory() } label: { Text("Clear") }
                        .tint(Crimson.accent2)
                        .disabled(store.history.isEmpty)
                }
            }
        }
        .tint(Crimson.accent)
    }
}
