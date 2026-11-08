import SwiftUI
import UIKit

/// Browses all your photos and videos on the Immich server in a grid, and opens them in the editor.
@MainActor
final class ImmichGalleryModel: ObservableObject {
    @Published var assets: [ImmichAsset] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published var error: String?
    @Published private(set) var reachedEnd = false

    private var page = 1
    private var client: ImmichClient { ImmichClient(settings: ImmichSettings.load()) }

    var isConfigured: Bool { ImmichSettings.load().isConfigured }

    func reload() async {
        guard isConfigured else { return }
        loading = true
        error = nil
        page = 1
        reachedEnd = false
        do {
            let (items, last) = try await client.assets(page: 1)
            assets = items
            reachedEnd = last
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func loadMoreIfNeeded(current asset: ImmichAsset) async {
        guard !loadingMore, !reachedEnd, !loading,
              let index = assets.firstIndex(of: asset), index >= assets.count - 12 else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let (items, last) = try await client.assets(page: page + 1)
            page += 1
            // Guard against overlap if the library changed between pages.
            let known = Set(assets.map(\.id))
            assets.append(contentsOf: items.filter { !known.contains($0.id) })
            reachedEnd = last
        } catch {
            reachedEnd = true   // stop hammering a failing server; the grid keeps what it has
        }
    }

    /// Downloads the original and hands back an edit source (image data, or a temp file for video).
    func open(_ asset: ImmichAsset) async -> EditSource? {
        do {
            let data = try await client.original(asset.id)
            if asset.isVideo {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("immich-\(asset.id)").appendingPathExtension(ext(asset.fileName))
                try data.write(to: url)
                return EditSource(videoURL: url)
            }
            return EditSource(data: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func ext(_ name: String) -> String {
        let e = (name as NSString).pathExtension
        return e.isEmpty ? "mov" : e
    }
}

/// A small in-memory cache so thumbnails aren't fetched again while scrolling.
enum ImmichThumbCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct ImmichGalleryView: View {
    @StateObject private var model = ImmichGalleryModel()
    @Environment(\.dismiss) private var dismiss
    @State private var opening = false
    @State private var showLocal = false
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var toast: String?
    @StateObject private var batch = BatchProcessor()
    var onOpen: (EditSource) -> Void

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if !model.isConfigured {
                    setupPrompt
                } else {
                    grid
                }
            }
            .navigationTitle(selecting ? "\(selected.count) selected" : (model.isConfigured ? "Immich" : "Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selecting { Button("Cancel") { selecting = false; selected = [] } }
                    else { Button("Close") { dismiss() } }
                }
                if model.isConfigured {
                    ToolbarItem(placement: .confirmationAction) {
                        if selecting {
                            Button(selected.count == model.assets.count ? "None" : "All") {
                                selected = selected.count == model.assets.count ? [] : Set(model.assets.map(\.id))
                            }
                        } else {
                            Menu {
                                Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                Button { selecting = true } label: { Label("Select & batch-edit", systemImage: "checkmark.circle") }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if selecting { batchBar } }
            .overlay { if opening || batch.running { batchHUD } }
        }
        .preferredColorScheme(.dark)
        .task { if model.assets.isEmpty { await model.reload() } }
        .onChange(of: batch.finished) { _, text in
            guard let text else { return }
            selecting = false
            selected = []
            toast = text
            batch.finished = nil
        }
        .alert("Batch edit", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("OK", role: .cancel) { toast = nil }
        } message: { Text(toast ?? "") }
        .fullScreenCover(isPresented: $showLocal) {
            GalleryView { source in
                showLocal = false
                dismiss()
                onOpen(source)
            }
        }
    }

    @ViewBuilder private var batchBar: some View {
        let count = selected.count
        let hasRecipe = RecipeClipboard.hasValue
        VStack(spacing: 4) {
            Button {
                let chosen = model.assets.filter { selected.contains($0.id) }
                if let recipe = RecipeClipboard.stored { batch.run(assets: chosen, recipe: recipe) }
            } label: {
                Text(hasRecipe ? "Apply copied edit to \(count)" : "Copy an edit in the editor first")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(count > 0 && hasRecipe ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(count > 0 && hasRecipe ? .black : .white)
            }
            .disabled(count == 0 || !hasRecipe || batch.running)
            Text("Edits a copy of each — your originals are untouched.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var batchHUD: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                if batch.running {
                    ProgressView(value: batch.progress).tint(.yellow).frame(width: 180)
                    Text(batch.status).font(.subheadline)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(22)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.assets) { asset in
                    Button { tap(asset) } label: {
                        ImmichThumbnail(asset: asset)
                            .overlay(alignment: .topLeading) {
                                if selecting {
                                    Image(systemName: selected.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(selected.contains(asset.id) ? Color.yellow : .white.opacity(0.9))
                                        .padding(5).shadow(radius: 2)
                                }
                            }
                            .overlay { if selecting && selected.contains(asset.id) { Color.yellow.opacity(0.18) } }
                    }
                    .task { await model.loadMoreIfNeeded(current: asset) }
                }
            }
            .padding(2)
            if model.loadingMore { ProgressView().tint(.white).padding() }
        }
        .overlay {
            if model.loading { ProgressView().tint(.white) }
            else if let error = model.error, model.assets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.icloud").font(.largeTitle)
                    Text("Couldn't reach Immich").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try again") { Task { await model.reload() } }.buttonStyle(.borderedProminent)
                }.padding()
            } else if model.assets.isEmpty {
                Text("No photos on Immich yet").foregroundStyle(.secondary)
            }
        }
        .refreshable { await model.reload() }
    }

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack").font(.largeTitle)
            Text("Connect Immich").font(.headline)
            Text("Add your Immich address and API key in Camera settings → Immich to browse everything on your server here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button("Browse this iPhone instead") { showLocal = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func tap(_ asset: ImmichAsset) {
        if selecting {
            if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
        } else {
            open(asset)
        }
    }

    private func open(_ asset: ImmichAsset) {
        guard !opening else { return }
        opening = true
        Task {
            let source = await model.open(asset)
            opening = false
            if let source {
                dismiss()
                onOpen(source)
            }
        }
    }
}

/// One grid cell: a cached Immich thumbnail with a video / RAW-ish badge.
private struct ImmichThumbnail: View {
    let asset: ImmichAsset
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                if asset.isVideo {
                    Text(Self.duration(asset.durationSeconds ?? 0))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.4), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.width)
            .clipped()
            .task(id: asset.id) { await load() }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func load() async {
        if let cached = ImmichThumbCache.shared.object(forKey: asset.id as NSString) {
            image = cached
            return
        }
        let client = ImmichClient(settings: ImmichSettings.load())
        if let data = try? await client.thumbnail(asset.id), let ui = UIImage(data: data) {
            ImmichThumbCache.shared.setObject(ui, forKey: asset.id as NSString)
            image = ui
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
