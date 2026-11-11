import SwiftUI

/// Shows the facts this companion has learned about you (its scoped memory in jarvis-core).
struct MemoryView: View {
    let companion: Companion
    @EnvironmentObject private var settings: KithSettings
    @Environment(\.dismiss) private var dismiss
    @State private var facts: [String] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "brain").font(.largeTitle).foregroundStyle(Theme.secondaryText)
                        Text(error).font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    }.padding(.horizontal, 30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if facts.isEmpty {
                            Text("\(companion.name) hasn't learned anything about you yet — chat a while and they'll remember.")
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(facts, id: \.self) { fact in
                            Label(fact, systemImage: "sparkles").labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .navigationTitle("\(companion.name) remembers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true; error = nil
        do { facts = try await settings.client.facts(companion: companion) }
        catch { self.error = describeError(error) }
        loading = false
    }
}
