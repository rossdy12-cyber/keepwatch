import SwiftUI

struct NFBrowserView: View {
    @EnvironmentObject private var settings: NFAppSettings
    @EnvironmentObject private var offlineStore: NFOfflineStore
    @EnvironmentObject private var downloadQueue: NFDownloadQueueService

    enum SortOption: String, CaseIterable, Identifiable {
        case name
        case date
        case size
        case type

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "Name"
            case .date: return "Date modified"
            case .size: return "Size"
            case .type: return "Type"
            }
        }
    }

    @State private var currentPath = "/"
    @State private var pathStack: [String] = []
    @State private var hasLoaded = false
    @State private var files: [NFRemoteFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedFile: NFRemoteFile?
    @State private var showImporter = false
    @State private var sortOption: SortOption = .name
    @State private var isGrid = false
    @State private var renameFile: NFRemoteFile?
    @State private var newFileName = ""
    @State private var moveFile: NFRemoteFile?
    @State private var destinationPath = "/"

    private var sortedFiles: [NFRemoteFile] {
        let base: [NFRemoteFile]
        switch sortOption {
        case .name:
            base = files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date:
            base = files.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        case .size:
            base = files.sorted { $0.size > $1.size }
        case .type:
            base = files.sorted { $0.fileExtension < $1.fileExtension }
        }
        return base.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return false
        }
    }

    private var isAtRoot: Bool {
        let normCurrent = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normRoot = settings.rootDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normCurrent == normRoot && pathStack.isEmpty
    }

    private var breadcrumbs: [(title: String, path: String)] {
        let clean = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else {
            return [("TrueNAS", "/")]
        }
        var items: [(String, String)] = [("TrueNAS", "/")]
        var running = ""
        for part in clean.split(separator: "/").map(String.init) {
            running += "/\(part)"
            items.append((part, running + "/"))
        }
        return items
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if settings.isConfigured && (!isAtRoot || breadcrumbs.count > 1) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if !isAtRoot {
                                Button {
                                    goBack()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                        Text("Back")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }

                            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    jumpToBreadcrumb(crumb.path, index: idx)
                                } label: {
                                    Text(crumb.title)
                                        .font(.caption.weight(idx == breadcrumbs.count - 1 ? .bold : .regular))
                                        .foregroundStyle(idx == breadcrumbs.count - 1 ? .primary : .secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .background(.bar)
                    Divider()
                }

                Group {
                    if !settings.isConfigured {
                        ContentUnavailableView(
                            "WebDAV not configured",
                            systemImage: "server.rack",
                            description: Text("Add your TrueNAS WebDAV server details in Settings.")
                        )
                    } else if isLoading {
                        VStack(spacing: 12) {
                            Spacer()
                            ProgressView("Loading files…")
                            Spacer()
                        }
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label("Unable to load files", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Retry") {
                                Task { await load() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if sortedFiles.isEmpty {
                        ContentUnavailableView(
                            "Folder is empty",
                            systemImage: "folder",
                            description: Text(currentPath)
                        )
                    } else if isGrid {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                                ForEach(sortedFiles) { file in
                                    NFFileCell(file: file)
                                        .onTapGesture {
                                            if file.isDirectory {
                                                openFolder(file.path)
                                            } else {
                                                selectedFile = file
                                            }
                                        }
                                        .contextMenu { contextMenu(for: file) }
                                }
                            }
                            .padding()
                        }
                    } else {
                        List(sortedFiles) { file in
                            Button {
                                if file.isDirectory {
                                    openFolder(file.path)
                                } else {
                                    selectedFile = file
                                }
                            } label: {
                                HStack {
                                    NFFileRow(file: file)
                                    if file.isDirectory {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: file) }
                        }
                    }
                }
            }
            .navigationTitle(isAtRoot ? "Files" : (currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString).lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        if !isAtRoot {
                            Button {
                                goBack()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                            }
                        }

                        Menu {
                            Picker("Sort by", selection: $sortOption) {
                                ForEach(SortOption.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }

                            Button {
                                isGrid.toggle()
                            } label: {
                                Label(
                                    isGrid ? "List view" : "Grid view",
                                    systemImage: isGrid ? "list.bullet" : "square.grid.2x2"
                                )
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!settings.isConfigured || isLoading)

                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(!settings.isConfigured)
                    }
                }
            }
            .refreshable {
                await load()
            }
            .onAppear {
                if !hasLoaded {
                    hasLoaded = true
                    if currentPath == "/" {
                        currentPath = settings.rootDirectory
                    }
                    Task { await load() }
                }
            }
            .sheet(item: $selectedFile) { file in
                NFFilePreviewView(file: file)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        await upload(url)
                    }
                }
            }
            .alert("Rename", isPresented: Binding(
                get: { renameFile != nil },
                set: { if !$0 { renameFile = nil } }
            )) {
                TextField("New name", text: $newFileName)

                Button("Rename") {
                    Task { await rename() }
                }

                Button("Cancel", role: .cancel) {
                    renameFile = nil
                }
            }
            .alert("Move to folder", isPresented: Binding(
                get: { moveFile != nil },
                set: { if !$0 { moveFile = nil } }
            )) {
                TextField("Destination path", text: $destinationPath)

                Button("Move") {
                    Task { await move() }
                }

                Button("Cancel", role: .cancel) {
                    moveFile = nil
                }
            }
        }
    }

    init(initialPath: String? = nil) {
        _currentPath = State(initialValue: initialPath ?? "/")
    }

    private func openFolder(_ targetPath: String) {
        pathStack.append(currentPath)
        currentPath = targetPath
        Task { await load() }
    }

    private func goBack() {
        if let previous = pathStack.popLast() {
            currentPath = previous
        } else {
            let trimmed = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parent = (trimmed as NSString).deletingLastPathComponent
            currentPath = parent.isEmpty ? settings.rootDirectory : "/\(parent)/"
        }
        Task { await load() }
    }

    private func jumpToBreadcrumb(_ path: String, index: Int) {
        if index == 0 {
            pathStack.removeAll()
            currentPath = settings.rootDirectory
        } else {
            if index < pathStack.count {
                pathStack = Array(pathStack.prefix(index))
            }
            currentPath = path
        }
        Task { await load() }
    }

    @ViewBuilder
    private func contextMenu(for file: NFRemoteFile) -> some View {
        Button {
            offlineStore.togglePin(file.path)
        } label: {
            Label(
                offlineStore.isPinned(file.path) ? "Unpin" : "Pin",
                systemImage: offlineStore.isPinned(file.path) ? "pin.slash" : "pin"
            )
        }

        if !file.isDirectory {
            Button {
                Task {
                    await downloadQueue.download(file)
                }
            } label: {
                Label("Download for offline", systemImage: "arrow.down.circle")
            }
        }

        Button {
            renameFile = file
            newFileName = file.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            moveFile = file
            destinationPath = settings.rootDirectory
        } label: {
            Label("Move", systemImage: "folder.badge.plus")
        }

        Button(role: .destructive) {
            Task { await delete(file) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil

        do {
            let client = NFWebDAVClient(settings: settings)
            files = try await client.listDirectory(at: currentPath)
        } catch {
            errorMessage = error.localizedDescription
            files = []
        }

        isLoading = false
    }

    private func upload(_ url: URL) async {
        isLoading = true
        errorMessage = nil

        do {
            let client = NFWebDAVClient(settings: settings)
            let securedURL = url.startAccessingSecurityScopedResource()
            defer { if securedURL { url.stopAccessingSecurityScopedResource() } }

            try await client.upload(url, to: currentPath)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func rename() async {
        guard let file = renameFile, !newFileName.isEmpty else {
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let client = NFWebDAVClient(settings: settings)
            try await client.rename(file, to: newFileName)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }

        renameFile = nil
        isLoading = false
    }

    private func move() async {
        guard let file = moveFile else {
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let client = NFWebDAVClient(settings: settings)
            try await client.move(file, to: destinationPath)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }

        moveFile = nil
        isLoading = false
    }

    private func delete(_ file: NFRemoteFile) async {
        isLoading = true
        errorMessage = nil

        do {
            let client = NFWebDAVClient(settings: settings)
            try await client.delete(file)
            offlineStore.remove(file)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct NFFileRow: View {
    let file: NFRemoteFile
    @EnvironmentObject private var offlineStore: NFOfflineStore

    var body: some View {
        HStack {
            Image(systemName: file.systemImage)
                .foregroundStyle(file.isDirectory ? .blue : .secondary)

            VStack(alignment: .leading) {
                Text(file.name)
                    .font(.body)

                if !file.isDirectory {
                    Text(file.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if offlineStore.isPinned(file.path) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if offlineStore.isDownloaded(file) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct NFFileCell: View {
    let file: NFRemoteFile
    @EnvironmentObject private var offlineStore: NFOfflineStore

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: file.systemImage)
                .font(.title2)
                .foregroundStyle(file.isDirectory ? .blue : .secondary)

            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if offlineStore.isPinned(file.path) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
