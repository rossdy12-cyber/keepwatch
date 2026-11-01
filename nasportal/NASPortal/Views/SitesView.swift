import SwiftUI

/// Shortcuts to each app's web page. Tap to open; Edit to add, remove, reorder or change them.
struct SitesView: View {
    @EnvironmentObject private var store: PortalStore
    @State private var open: WebDestination?
    @State private var editing: Site?
    @State private var editMode: EditMode = .inactive

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if editMode.isEditing {
                    List {
                        ForEach(store.sites) { site in
                            Button {
                                editing = site
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.name).foregroundStyle(.white)
                                        Text(site.address).font(.caption).foregroundStyle(Theme.secondaryText)
                                    }
                                } icon: {
                                    Image(systemName: site.symbol).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .onDelete { store.sites.remove(atOffsets: $0) }
                        .onMove { store.sites.move(fromOffsets: $0, toOffset: $1) }
                        Button("Restore the original list") { store.resetSites() }
                            .foregroundStyle(Theme.warning)
                    }
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.sites) { site in
                                Button {
                                    if let url = site.url { open = WebDestination(title: site.name, url: url) }
                                } label: {
                                    SiteTile(site: site)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { editing = site } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) {
                                        store.sites.removeAll { $0.id == site.id }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(16)
                        if store.sites.isEmpty {
                            MessageCard(symbol: "square.grid.2x2", title: "No shortcuts",
                                        message: "Tap + to add the web page of an app on your NAS.")
                                .padding(16)
                        }
                    }
                }
            }
            .navigationTitle("Apps")
            .portalChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editing = Site(name: "", address: "https://")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add shortcut")
                }
            }
            .fullScreenCover(item: $open) { destination in
                WebScreen(destination: destination, showsDone: true)
            }
            .sheet(item: $editing) { site in
                SiteEditor(site: site) { saved in
                    if let index = store.sites.firstIndex(where: { $0.id == saved.id }) {
                        store.sites[index] = saved
                    } else {
                        store.sites.append(saved)
                    }
                }
            }
        }
    }
}

struct SiteTile: View {
    let site: Site

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: site.symbol)
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .frame(height: 32)
            Text(site.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(.horizontal, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SiteEditor: View {
    @State var site: Site
    var onSave: (Site) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $site.name)
                    TextField("https://app.nas-server.co.uk", text: $site.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("A web address, or a Tailscale address and port such as http://100.85.127.42:8998.")
                }
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(PortalStore.symbolChoices, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .foregroundStyle(site.symbol == symbol ? Theme.background : Theme.accent)
                                .background(site.symbol == symbol ? Theme.accent : Theme.surface,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { site.symbol = symbol }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .portalChrome()
            .navigationTitle(site.name.isEmpty ? "New shortcut" : site.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        site.name = site.name.trimmingCharacters(in: .whitespaces)
                        site.address = site.address.trimmingCharacters(in: .whitespaces)
                        onSave(site)
                        dismiss()
                    }
                    .disabled(site.name.trimmingCharacters(in: .whitespaces).isEmpty || site.url == nil)
                }
            }
        }
    }
}
