import AVFoundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Browses your photos and videos in a grid, with a few filters, and opens them straight in the editor.
@MainActor
final class GalleryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", photos = "Photos", videos = "Videos", raw = "RAW", portrait = "Portrait", live = "Live"
        var id: String { rawValue }
    }

    @Published var assets: [PHAsset] = []
    @Published var filter: Filter = .all { didSet { if oldValue != filter { fetch() } } }
    @Published var status: PHAuthorizationStatus = .notDetermined
    @Published private(set) var loading = false

    let imageManager = PHCachingImageManager()

    func load() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                self.status = status
                if status == .authorized || status == .limited { self.fetch() }
            }
        }
    }

    private func fetch() {
        loading = true
        let filter = self.filter
        Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            switch filter {
            case .all: options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            case .photos, .raw: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            case .portrait: options.predicate = NSPredicate(format: "mediaSubtypes & %d != 0", PHAssetMediaSubtype.photoDepthEffect.rawValue)
            case .live: options.predicate = NSPredicate(format: "mediaSubtypes & %d != 0", PHAssetMediaSubtype.photoLive.rawValue)
            }
            if filter != .raw { options.fetchLimit = 1500 }
            let result = PHAsset.fetchAssets(with: options)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, stop in
                if filter == .raw {
                    if Self.isRAW(asset) { assets.append(asset) }
                    if assets.count >= 600 { stop.pointee = true }
                } else {
                    assets.append(asset)
                }
            }
            await MainActor.run {
                self.assets = assets
                self.loading = false
            }
        }
    }

    private static func isRAW(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { resource in
            if #available(iOS 14.0, *), let type = UTType(resource.uniformTypeIdentifier) {
                return type.conforms(to: .rawImage)
            }
            return resource.uniformTypeIdentifier.contains("raw") || resource.uniformTypeIdentifier.contains("dng")
        }
    }

    /// A playable file URL for a library video, for the video editor.
    func videoURL(for asset: PHAsset) async -> URL? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }
}

struct GalleryView: View {
    @StateObject private var model = GalleryModel()
    @Environment(\.dismiss) private var dismiss
    var onOpen: (EditSource) -> Void

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if model.status == .denied || model.status == .restricted {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                        Text("Lumen can't see your photos").font(.headline)
                        Text("Allow access in Settings → Lumen → Photos.").foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(model.assets, id: \.localIdentifier) { asset in
                                Button { open(asset) } label: { Thumbnail(asset: asset, manager: model.imageManager) }
                            }
                        }
                        .padding(2)
                    }
                    .overlay {
                        if model.loading { ProgressView().tint(.white) }
                        else if model.assets.isEmpty { Text("Nothing here").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $model.filter) {
                        ForEach(GalleryModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(.yellow)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if model.assets.isEmpty { model.load() } }
    }

    private func open(_ asset: PHAsset) {
        if asset.mediaType == .video {
            Task {
                if let url = await model.videoURL(for: asset) {
                    onOpen(EditSource(videoURL: url))
                    dismiss()
                }
            }
        } else {
            onOpen(EditSource(assetID: asset.localIdentifier))
            dismiss()
        }
    }
}

/// One grid cell: a cached thumbnail, with a small badge for video / Live / portrait / RAW.
private struct Thumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if let badge { Image(systemName: badge).font(.system(size: 11, weight: .bold)).padding(4).foregroundStyle(.white).shadow(radius: 2) }
                    }
                }
                if asset.mediaType == .video {
                    Text(Self.duration(asset.duration))
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
            .task(id: asset.localIdentifier) { await loadThumb(geometry.size.width) }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var badge: String? {
        if asset.mediaSubtypes.contains(.photoLive) { return "livephoto" }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { return "person.crop.circle" }
        return nil
    }

    private func loadThumb(_ width: CGFloat) async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = UIScreen.main.scale
        let target = CGSize(width: width * scale, height: width * scale)
        manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { result, _ in
            if let result { self.image = result }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
