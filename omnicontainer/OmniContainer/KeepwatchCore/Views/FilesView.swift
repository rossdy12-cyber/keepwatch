import QuickLook
import SwiftUI

struct FileEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: Double?
    var modified: Date?

    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "mkv", "mp4", "avi", "mov", "m4v", "ts", "webm": return "film"
        case "mp3", "flac", "m4a", "aac", "ogg", "wav", "opus": return "music.note"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw", "dng": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "gz", "tar", "xz": return "doc.zipper"
        case "txt", "log", "nfo", "srt", "md", "json", "yaml", "yml", "conf", "ini", "xml": return "doc.text"
        default: return "doc"
        }
    }

    static func parse(_ value: JSONValue) -> FileEntry? {
        guard let name = value["name"].string, let path = value["path"].string else { return nil }
        let type = (value["type"].string ?? "").uppercased()
        return FileEntry(
            name: name,
            path: path,
            isDirectory: type == "DIRECTORY",
            isSymlink: type == "SYMLINK",
            size: value["size"].double,
            modified: value["mtime"].date
        )
    }
}

struct FilesView: View {
    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack {
            Group {
                if settings[.truenas].isConfigured {
                    FolderView(path: "/mnt", title: "Storage")
                } else {
                    ScrollView {
                        MessageCard(symbol: "folder", title: "Connect your TrueNAS",
                                    message: "The file browser uses your TrueNAS API key. Add it in Settings.",
                                    color: Theme.accent, actionTitle: "Open Settings") { router.tab = .settings }
                            .padding(16)
                    }
                    .navigationTitle("Files")
                }
            }
            .keepwatchChrome()
            .navigationDestination(for: FileEntry.self) { entry in
                if entry.isDirectory {
                    FolderView(path: entry.path, title: entry.name)
                } else {
                    FileDetailView(entry: entry)
                }
            }
        }
    }
}

enum FileSort: String, CaseIterable {
    case name = "Name", size = "Size"
}

struct FolderView: View {
    let path: String
    let title: String

    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var store: TrueNASStore

    @State private var entries: [FileEntry] = []
    @State private var error: String?
    @State private var loading = true
    @State private var sort: FileSort = .name
    @State private var showHidden = false
    @AppStorage(HiddenPaths.storageKey) private var hiddenText = ""

    private var hidden: Set<String> { Set(HiddenPaths.decode(hiddenText)) }

    private var visible: [FileEntry] {
        let hidden = hidden
        let filtered = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") && !hidden.contains($0.path) }
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: return (a.size ?? 0) > (b.size ?? 0)
            }
        }
    }

    var body: some View {
        List {
            if let error {
                Text(error)
                    .foregroundStyle(Theme.warning)
                    .listRowBackground(Theme.surface)
            } else if loading && entries.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if visible.isEmpty {
                Text("This folder is empty.")
                    .foregroundStyle(Theme.secondaryText)
                    .listRowBackground(Theme.surface)
            }
            ForEach(visible) { entry in
                let isHidden = hidden.contains(entry.path)
                NavigationLink(value: entry) {
                    FileRow(entry: entry)
                        .opacity(isHidden ? 0.45 : 1)
                }
                .listRowBackground(Theme.surface)
                .swipeActions(edge: .trailing) {
                    hideButton(entry, isHidden: isHidden)
                }
                .contextMenu {
                    hideButton(entry, isHidden: isHidden)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Show hidden items", isOn: $showHidden)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .keepwatchChrome()
    }

    private func hideButton(_ entry: FileEntry, isHidden: Bool) -> some View {
        Button {
            hiddenText = HiddenPaths.toggled(entry.path, in: hiddenText)
        } label: {
            Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
        }
        .tint(Theme.secondaryText)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let client = try await store.connectedClient(settings[.truenas])
            let result = try await client.call("filesystem.listdir", [path])
            entries = result.array.compactMap(FileEntry.parse)
            error = nil
        } catch {
            if isCancellation(error) { return }
            self.error = describe(error)
        }
    }
}

/// Folders and files the user has hidden from the file browser. Only Keepwatch hides them; nothing on
/// the NAS changes.
enum HiddenPaths {
    static let storageKey = "hiddenPaths"

    static func decode(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }

    static func toggled(_ path: String, in text: String) -> String {
        var paths = decode(text)
        if let index = paths.firstIndex(of: path) {
            paths.remove(at: index)
        } else {
            paths.append(path)
        }
        return paths.sorted().joined(separator: "\n")
    }
}

struct FileRow: View {
    let entry: FileEntry

    private var details: String {
        var parts: [String] = []
        if !entry.isDirectory { parts.append(Format.bytes(entry.size)) }
        if let modified = entry.modified { parts.append(Format.dateTime(modified)) }
        if entry.isSymlink { parts.append("link") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol)
                .foregroundStyle(entry.isDirectory ? Theme.accent : Theme.secondaryText)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Details for one file, with a read-only preview / share. Nothing here can change files on the NAS.
struct FileDetailView: View {
    let entry: FileEntry

    @EnvironmentObject private var settings: ServiceSettings
    @EnvironmentObject private var store: TrueNASStore

    @State private var stat: JSONValue = .null
    @State private var error: String?
    @State private var downloading = false
    @State private var downloadedFile: URL?
    @State private var previewURL: URL?
    @State private var confirmLarge = false

    private static let largeFile: Double = 200 * 1024 * 1024

    private var size: Double? { stat["size"].double ?? entry.size }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: entry.symbol)
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline)
                        Text(Format.bytes(size)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Theme.surface)

            Section("Details") {
                row("Location", (entry.path as NSString).deletingLastPathComponent)
                row("Modified", Format.dateTime(stat["mtime"].date ?? entry.modified))
                row("Created", Format.dateTime(stat["btime"].date ?? stat["ctime"].date))
                row("Last opened", Format.dateTime(stat["atime"].date))
                row("Owner", [stat["user"].string ?? stat["uid"].string, stat["group"].string ?? stat["gid"].string]
                    .compactMap { $0 }.joined(separator: " : "))
                if let mode = stat["mode"].int {
                    row("Permissions", String(mode & 0o777, radix: 8))
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                Button {
                    if (size ?? 0) > Self.largeFile { confirmLarge = true } else { Task { await download() } }
                } label: {
                    HStack {
                        Label(downloadedFile == nil ? "Download & preview" : "Preview", systemImage: "eye")
                        Spacer()
                        if downloading { ProgressView() }
                    }
                }
                .disabled(downloading)
                if let downloadedFile {
                    ShareLink(item: downloadedFile) {
                        Label("Save or share…", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Files are copied to your iPhone to preview them. Nothing on the NAS is changed.")
            }
            .listRowBackground(Theme.surface)

            if let error {
                Text(error)
                    .foregroundStyle(Theme.warning)
                    .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .keepwatchChrome()
        .task { await loadStat() }
        .confirmationDialog("This file is \(Format.bytes(size)).", isPresented: $confirmLarge, titleVisibility: .visible) {
            Button("Download anyway") { Task { await download() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloading it over Tailscale may take a while and use space on your iPhone.")
        }
        .quickLookPreview($previewURL)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func loadStat() async {
        do {
            let client = try await store.connectedClient(settings[.truenas])
            stat = try await client.call("filesystem.stat", [entry.path])
        } catch {
            if !isCancellation(error) { self.error = describe(error) }
        }
    }

    private func download() async {
        if let downloadedFile {
            previewURL = downloadedFile
            return
        }
        downloading = true
        defer { downloading = false }
        do {
            let client = try await store.connectedClient(settings[.truenas])
            let url = try await client.downloadURL(for: entry.path, filename: entry.name)
            let (temporary, response) = try await httpSession.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.http(http.statusCode)
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(entry.name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            downloadedFile = destination
            previewURL = destination
            error = nil
        } catch {
            if !isCancellation(error) { self.error = describe(error) }
        }
    }
}
