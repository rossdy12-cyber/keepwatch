import SwiftUI

struct LVAddLinkView: View {
    @EnvironmentObject private var linkStore: LVLinkStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var pageDescription = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var metadata: LVPageMetadata?
    @State private var fetching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Link") {
                    TextField("https://example.com/article", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: url) { _, _ in metadata = nil }
                    if linkStore.containsNormalizedURL(url) { Text("This link is already saved.").foregroundStyle(.orange) }
                    Button(fetching ? "Fetching…" : "Fetch metadata") {
                        let requestedURL = url
                        fetching = true
                        Task { @MainActor in
                            defer { fetching = false }
                            do {
                                let result = try await LVMetadataService().fetchMetadata(for: requestedURL)
                                guard url == requestedURL else { return }
                                metadata = result
                                if title.isEmpty { title = result.title }
                                if pageDescription.isEmpty { pageDescription = result.description }
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(fetching || LVLinkStore.webURL(url) == nil)
                }
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $pageDescription, axis: .vertical)
                    TextField("Notes", text: $notes, axis: .vertical)
                    TextField("Tags, comma separated", text: $tags).textInputAutocapitalization(.never)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = linkStore.storageError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Save Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parsed = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                        let item = LVLinkItem(url: url.trimmingCharacters(in: .whitespacesAndNewlines), title: title, pageDescription: pageDescription, notes: notes, tags: parsed, faviconURL: metadata?.faviconURL, canonicalURL: metadata?.canonicalURL, siteName: metadata?.siteName)
                        if linkStore.add(item) { dismiss() } else { error = linkStore.storageError ?? "This link could not be saved." }
                    }.disabled(fetching || LVLinkStore.webURL(url) == nil || linkStore.containsNormalizedURL(url))
                }
            }
        }
    }
}
