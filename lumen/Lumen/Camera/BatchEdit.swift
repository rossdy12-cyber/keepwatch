import Photos
import SwiftUI
import UIKit

/// Applies one set of copied edits to several Immich photos at once, saving each as a new edited copy.
@MainActor
final class BatchProcessor: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published var finished: String?

    private let renderQueue = DispatchQueue(label: "lumen.batch", qos: .userInitiated)

    func run(assets: [ImmichAsset], recipe: EditRecipe) {
        let photos = assets.filter { !$0.isVideo }
        guard !photos.isEmpty else { finished = "Pick some photos first (videos are skipped)."; return }
        running = true
        progress = 0
        let toImmich = ImmichBackup.shared.isConfigured
        let client = ImmichClient(settings: ImmichSettings.load())
        var options = ExportOptions.load()
        options.format = .heic           // keep uploads to a format the queue labels correctly

        Task {
            var ok = 0, failed = 0
            for (index, asset) in photos.enumerated() {
                status = "Editing \(index + 1) of \(photos.count)…"
                progress = Double(index) / Double(photos.count)
                do {
                    let original = try await client.original(asset.id)
                    guard let data = await render(original, recipe: recipe, options: options) else { failed += 1; continue }
                    if toImmich {
                        ImmichBackup.shared.add(resources: [(.photo, data)], pairedVideo: nil)
                    } else {
                        try await saveToPhotos(data)
                    }
                    ok += 1
                } catch {
                    failed += 1
                }
            }
            if toImmich { ImmichBackup.shared.kick() }
            progress = 1
            running = false
            finished = failed == 0
                ? "Edited \(ok) photo\(ok == 1 ? "" : "s"). \(toImmich ? "Uploading the copies to Immich." : "Saved to Photos.")"
                : "Edited \(ok), \(failed) failed."
        }
    }

    private func render(_ data: Data, recipe: EditRecipe, options: ExportOptions) async -> Data? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let source = PhotoSource(data: data),
                      let image = PhotoRenderer.render(source, recipe: recipe, scale: 1) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PhotoRenderer.encode(image, options: options))
            }
        }
    }

    private func saveToPhotos(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
