import SwiftUI
import PhotosUI

struct LibraryView: View {
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var vault: VaultModel

    @State private var navigationPath = NavigationPath()
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var uploadMessage: String?
    @State private var viewerItem: VaultItem?
    @State private var isShowingNewFolder = false
    @State private var newFolderName = ""
    @State private var itemPendingDelete: VaultItem?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Vault")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            auth.lock()
                        } label: {
                            Image(systemName: "lock.fill")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        PhotosPicker(
                            selection: $selectedItems,
                            matching: .any(of: [.images, .videos])
                        ) {
                            Image(systemName: "plus")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                isShowingNewFolder = true
                            } label: {
                                Label("New folder", systemImage: "folder.badge.plus")
                            }

                            NavigationLink(value: SettingsRoute()) {
                                Label("Settings", systemImage: "gearshape")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .refreshable {
                    await vault.list(vault.currentPath)
                }
                .task {
                    await vault.list("")
                }
                .onChange(of: selectedItems) { _, _ in
                    Task {
                        await uploadSelected()
                    }
                }
                .navigationDestination(for: VaultItem.self) { folder in
                    FolderView(folder: folder)
                }
                .navigationDestination(for: SettingsRoute.self) { _ in
                    SettingsView()
                }
                .fullScreenCover(item: $viewerItem) { item in
                    MediaViewer(item: item)
                }
                .alert("New folder", isPresented: $isShowingNewFolder) {
                    TextField("Folder name", text: $newFolderName)

                    Button("Create") {
                        Task {
                            do {
                                try await vault.createFolder(newFolderName, in: vault.currentPath)
                                newFolderName = ""
                                await vault.list(vault.currentPath)
                            } catch {
                                vault.errorMessage = error.localizedDescription
                            }
                        }
                    }

                    Button("Cancel", role: .cancel) { }
                }
                .confirmationDialog(
                    "Delete \(itemPendingDelete?.name ?? "this item")?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task {
                            if let item = itemPendingDelete {
                                do {
                                    try await vault.delete(item)
                                } catch {
                                    vault.errorMessage = error.localizedDescription
                                }
                            }

                            itemPendingDelete = nil
                            await vault.list(vault.currentPath)
                        }
                    }

                    Button("Cancel", role: .cancel) {
                        itemPendingDelete = nil
                    }
                }
                .overlay {
                    if isUploading {
                        ProgressView("Uploading…")
                            .padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    }
                }
                .alert("Upload", isPresented: .constant(uploadMessage != nil)) {
                    Button("OK") { uploadMessage = nil }
                } message: {
                    Text(uploadMessage ?? "")
                }
        }
    }

    private var content: some View {
        Group {
            if vault.isLoading {
                ProgressView("Loading Vault…")
            } else if let error = vault.errorMessage {
                ContentUnavailableView(
                    "Cannot load Vault",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if vault.items.isEmpty {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text("Upload photos or videos to this folder.")
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 105), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(vault.items) { item in
                            VaultCell(item: item)
                                .onTapGesture {
                                    if item.isDirectory {
                                        navigationPath.append(item)
                                    } else if item.isImage || item.isVideo {
                                        viewerItem = item
                                    }
                                }
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
                    .padding(12)
                }
            }
        }
    }

    private func uploadSelected() async {
        guard !selectedItems.isEmpty else { return }

        isUploading = true
        var uploaded = 0

        for selection in selectedItems {
            if let data = try? await selection.loadTransferable(type: Data.self) {
                let extensionName = selection.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
                let filename = UUID().uuidString + "." + extensionName

                do {
                    try await vault.upload(
                        data: data,
                        filename: filename,
                        folder: vault.currentPath
                    )

                    uploaded += 1
                } catch {
                    uploadMessage = error.localizedDescription
                }
            }
        }

        selectedItems = []
        isUploading = false
        uploadMessage = "Uploaded \(uploaded) item(s)."

        await vault.list(vault.currentPath)
    }
}

struct SettingsRoute: Hashable {}

struct FolderView: View {
    @EnvironmentObject private var vault: VaultModel
    let folder: VaultItem

    var body: some View {
        Group {
            if vault.isLoading {
                ProgressView()
            } else if vault.items.isEmpty {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text("This folder contains no photos or videos.")
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 105), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(vault.items) { item in
                            VaultCell(item: item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vault.list(folder.path)
        }
    }
}

struct VaultCell: View {
    let item: VaultItem

    var body: some View {
        ZStack {
            if item.isDirectory {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.accentColor.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)

                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            } else if item.isImage {
                AuthenticatedImage(item: item)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
            } else if item.isVideo {
                AuthenticatedImage(item: item)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                    }
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.gray.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)

                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
