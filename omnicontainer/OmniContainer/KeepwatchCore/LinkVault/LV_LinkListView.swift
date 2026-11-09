import SwiftUI

struct LVLinkListView: View {
    @EnvironmentObject private var linkStore: LVLinkStore
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var filter = LVLinkFilter.all
    @State private var showAddLink = false

    private var filteredLinks: [LVLinkItem] {
        linkStore.links.filter { link in
            let status: Bool
            switch filter {
            case .all: status = !link.isArchived
            case .unread: status = !link.isArchived && !link.isRead
            case .read: status = !link.isArchived && link.isRead
            case .favourites: status = !link.isArchived && link.isFavourite
            case .archived: status = link.isArchived
            }
            return status && (selectedTag == nil || link.tags.contains(selectedTag!)) && (searchText.isEmpty || link.searchableText.contains(searchText.lowercased()))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if linkStore.links.isEmpty {
                    ContentUnavailableView("No saved links", systemImage: "bookmark", description: Text("Save articles and references here."))
                } else if filteredLinks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredLinks) { link in
                        NavigationLink(value: link.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(link.displayTitle).font(.headline).lineLimit(2)
                                    Spacer()
                                    if link.isFavourite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                    if link.articleText != nil { Image(systemName: "book.fill").foregroundStyle(.green) }
                                }
                                Text(link.displayHost).font(.caption).foregroundStyle(.secondary)
                                if !link.pageDescription.isEmpty { Text(link.pageDescription).font(.footnote).lineLimit(2) }
                                Text(link.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption)
                            }.opacity(link.isRead ? 0.65 : 1)
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let link = linkStore.links.first(where: { $0.id == id }) { LVLinkDetailView(link: link) }
            }
            .navigationTitle("LinkVault")
            .searchable(text: $searchText, prompt: "Search links and offline articles")
            .toolbar { Button { showAddLink = true } label: { Image(systemName: "plus") } }
            .safeAreaInset(edge: .top) {
                VStack {
                    if let error = linkStore.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(LVLinkFilter.allCases) { item in
                                Button(item.title) { filter = item }.buttonStyle(.bordered).tint(filter == item ? .accentColor : .secondary)
                            }
                            ForEach(linkStore.allTags(), id: \.self) { tag in
                                Button("#\(tag)") { selectedTag = selectedTag == tag ? nil : tag }.buttonStyle(.bordered).tint(selectedTag == tag ? .accentColor : .secondary)
                            }
                        }.padding(.horizontal)
                    }
                }.padding(.vertical, 6).background(.bar)
            }
            .sheet(isPresented: $showAddLink) { LVAddLinkView() }
        }
    }
}

enum LVLinkFilter: String, CaseIterable, Identifiable {
    case all, unread, read, favourites, archived
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
