import SwiftUI
import PhotosUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            FolderBrowser(path: "", title: "Vault")
        }
    }
}

struct SettingsRoute: Hashable {}

struct FolderView: View {
    let folder: VaultItem

    var body: some View {
        FolderBrowser(path: folder.path, title: folder.name)
    }
}

private struct FolderBrowser: View {
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var connection: VaultModel
    @StateObject private var browser = VaultModel()
    let path: String
    let title: String

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var message: String?
    @State private var viewerItem: VaultItem?
    @State private var isShowingNewFolder = false
    @State private var newFolderName = ""
    @State private var itemPendingDelete: VaultItem?
    @State private var showDeleteConfirmation = false
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if browser.isLoading || !hasLoaded {
                    ProgressView("Loading Vault…")
                        .padding()
                }
                if let error = browser.errorMessage {
                    ContentUnavailableView(
                        "Cannot load folder",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    Button("Retry") {
                        Task { await reload() }
                    }
                } else if hasLoaded && !browser.isLoading && browser.items.isEmpty {
                    ContentUnavailableView(
                        "Empty folder",
                        systemImage: "folder",
                        description: Text("There are no files or folders here.")
                    )
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 105), spacing: 8)],
                    spacing: 12
                ) {
                    ForEach(browser.items) { item in
                        cell(for: item)
                            .contextMenu {
                                Button(role: .destructive) {
                                    itemPendingDelete = item
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if path.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button { auth.lock() } label: {
                        Image(systemName: "lock.fill")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $selectedItems, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "plus")
                }
                .disabled(isUploading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingNewFolder = true
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: selectedItems) { _, _ in
            Task { await uploadSelected() }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(item: item, items: browser.items)
                .environmentObject(browser)
        }
        .alert("New folder", isPresented: $isShowingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do {
                        browser.settings = connection.settings
                        try await browser.createFolder(name, in: path)
                        newFolderName = ""
                        await reload()
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Delete \(itemPendingDelete?.name ?? "this item")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let item = itemPendingDelete
                itemPendingDelete = nil
                Task {
                    guard let item else { return }
                    do {
                        browser.settings = connection.settings
                        try await browser.delete(item)
                        await reload()
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { itemPendingDelete = nil }
        }
        .overlay {
            if isUploading {
                ProgressView("Uploading…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .alert("Vault", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func cell(for item: VaultItem) -> some View {
        if item.isDirectory {
            NavigationLink {
                FolderView(folder: item)
            } label: {
                VaultCell(item: item)
                    .environmentObject(browser)
            }
            .buttonStyle(.plain)
        } else if item.isImage || item.isVideo {
            Button {
                viewerItem = item
            } label: {
                VaultCell(item: item)
                    .environmentObject(browser)
            }
            .buttonStyle(.plain)
        } else {
            VaultCell(item: item)
                .environmentObject(browser)
        }
    }

    @MainActor
    private func reload() async {
        guard !browser.isLoading, !Task.isCancelled else { return }
        browser.settings = connection.settings
        await browser.list(path)
        if Task.isCancelled {
            browser.errorMessage = nil
            return
        }
        hasLoaded = true
    }

    @MainActor
    private func uploadSelected() async {
        guard !selectedItems.isEmpty, !isUploading else { return }
        let selections = selectedItems
        selectedItems = []
        isUploading = true
        browser.settings = connection.settings
        var uploaded = 0
        var failures: [String] = []
        for selection in selections {
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    failures.append("Could not read a selected item.")
                    continue
                }
                let ext = selection.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
                try await browser.upload(data: data, filename: UUID().uuidString + "." + ext, folder: path)
                uploaded += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isUploading = false
        message = "Uploaded \(uploaded) item(s)."
        if let failure = failures.first {
            message = "Uploaded \(uploaded) item(s); \(failures.count) failed. \(failure)"
        }
        await reload()
    }
}

struct VaultCell: View {
    let item: VaultItem

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        ZStack {
                            Color.accentColor.opacity(0.12)
                            if item.isDirectory {
                                Image(systemName: "folder.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                            } else if item.isImage {
                                AuthenticatedImage(item: item)
                            } else if item.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(item.name)
    }
}
