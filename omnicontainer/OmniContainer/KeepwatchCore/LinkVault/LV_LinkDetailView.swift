import SwiftUI

struct LVLinkDetailView: View {
    @EnvironmentObject private var linkStore: LVLinkStore
    let link: LVLinkItem
    @State private var fetching = false
    @State private var error: String?
    private var current: LVLinkItem { linkStore.links.first(where: { $0.id == link.id }) ?? link }

    private func binding<T>(_ key: WritableKeyPath<LVLinkItem, T>) -> Binding<T> {
        Binding(get: { current[keyPath: key] }, set: { value in
            var updated = current
            updated[keyPath: key] = value
            linkStore.update(updated)
        })
    }

    var body: some View {
        Form {
            Section("Link") {
                if let raw = current.faviconURL, let url = LVLinkStore.webURL(raw) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "globe") }.frame(width: 28, height: 28)
                }
                if let url = LVLinkStore.webURL(current.url) {
                    Link(current.displayHost, destination: url)
                    ShareLink(item: url)
                }
                TextField("Title", text: binding(\.title))
                TextField("Description", text: binding(\.pageDescription), axis: .vertical)
                TextField("Notes", text: binding(\.notes), axis: .vertical)
                TextField("Tags, comma separated", text: Binding(get: { current.tags.joined(separator: ", ") }, set: { value in
                    var updated = current
                    updated.tags = Array(Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                    linkStore.update(updated)
                }))
            }
            Section("Status") {
                Toggle("Favourite", isOn: binding(\.isFavourite))
                Toggle("Mark as read", isOn: Binding(get: { current.isRead }, set: { linkStore.markRead(current, isRead: $0) }))
                Toggle("Archive", isOn: binding(\.isArchived))
            }
            Section("Offline reading") {
                if let article = current.articleText, !article.isEmpty {
                    NavigationLink("Open Reader Mode") { LVReaderView(link: current) }
                }
                if let date = current.snapshotAt { Text("Saved \(date.formatted())").font(.caption) }
                Button(fetching ? "Saving…" : "Save offline article") {
                    let id = link.id
                    let raw = current.url
                    fetching = true
                    Task { @MainActor in
                        defer { fetching = false }
                        do {
                            let article = try await LVMetadataService().fetchArticle(for: raw)
                            guard var latest = linkStore.links.first(where: { $0.id == id }), latest.url == raw else { return }
                            latest.articleText = article
                            latest.snapshotAt = Date()
                            linkStore.update(latest)
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(fetching)
            }
            Section("Metadata") {
                Text("Saved \(current.createdAt.formatted())")
                if let date = current.readAt { Text("Read \(date.formatted())") }
                if let site = current.siteName { Text(site) }
                if let raw = current.canonicalURL, let url = LVLinkStore.webURL(raw) { Link("Canonical URL", destination: url) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let error = linkStore.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Link Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
