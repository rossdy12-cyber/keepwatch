import CoreImage
import Photos
import UIKit

/// What to edit: a photo just taken (by its Photos ID) or one picked from the library (its data).
struct EditSource: Identifiable {
    let id = UUID()
    var data: Data?
    var assetID: String?
    var videoURL: URL?

    init(data: Data) { self.data = data }
    init(assetID: String) { self.assetID = assetID }
    init(videoURL: URL) { self.videoURL = videoURL }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var recipe = EditRecipe() {
        didSet { if recipe != oldValue { scheduleRender() } }
    }
    @Published private(set) var preview: UIImage?
    @Published private(set) var original: UIImage?
    @Published private(set) var lookThumbnails: [String: UIImage] = [:]
    @Published private(set) var isRAW = false
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published var message: String?
    @Published var shareURL: URL?
    @Published private(set) var analysing = false
    @Published private(set) var hasSubject = false

    private var source: PhotoSource?
    private var analysis: AIAnalysis?
    private var previewScale: CGFloat = 1
    private var generation = 0
    private let renderQueue = DispatchQueue(label: "lumen.editor.render", qos: .userInitiated)

    // MARK: Loading

    func load(_ edit: EditSource) async {
        loading = true
        defer { loading = false }
        var data = edit.data
        if data == nil, let id = edit.assetID {
            data = await Self.loadAsset(id)
        }
        guard let data, let source = PhotoSource(data: data) else {
            message = "Couldn't open that photo."
            return
        }
        self.source = source
        isRAW = source.isRAW
        let fullSize = await Self.extent(of: source)
        let longest = max(fullSize.width, fullSize.height)
        previewScale = longest > 0 ? min(1, 1800 / longest) : 1
        original = await renderImage(EditRecipe(), scale: previewScale)
        preview = original
        loading = false
        await analyse()
        await makeLookThumbnails()
    }

    /// Runs the on-device AI once: Apple's auto-enhance analysis and the subject outline.
    private func analyse() async {
        guard let source else { return }
        analysing = true
        let scale = previewScale
        let result: AIAnalysis = await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let image = PhotoRenderer.render(source, recipe: EditRecipe(), scale: scale) else {
                    continuation.resume(returning: AIAnalysis())
                    return
                }
                let placed = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                continuation.resume(returning: AIAnalyser.analyse(placed, cgImage: PhotoRenderer.cgImage(placed), findSubject: true))
            }
        }
        analysis = result
        hasSubject = result.hasSubject
        analysing = false
        if recipe.autoEnhance > 0 || recipe.subjectPop > 0 || recipe.backgroundBlur > 0 { scheduleRender() }
    }

    /// One tap: Apple's auto-enhance, a little subject pop when there's a subject, and noise clean-up for RAW.
    func magicEnhance() {
        var updated = recipe
        updated.autoEnhance = 1
        if hasSubject { updated.subjectPop = max(updated.subjectPop, 0.3) }
        if isRAW { updated.noiseReduction = max(updated.noiseReduction, 0.25) }
        updated.clarity = max(updated.clarity, 0.15)
        recipe = updated
    }

    /// The photo's data from Photos: the RAW if it was shot as RAW+HEIF, else the latest version.
    private static func loadAsset(_ id: String) async -> Data? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .alternatePhoto }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
        guard let resource else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var collected = Data()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                collected.append(chunk)
            } completionHandler: { error in
                continuation.resume(returning: error == nil ? collected : nil)
            }
        }
    }

    private static func extent(of source: PhotoSource) async -> CGRect {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = PhotoRenderer.render(source, recipe: EditRecipe(), scale: 0.05)
                let small = image?.extent ?? .zero
                continuation.resume(returning: CGRect(x: 0, y: 0, width: small.width / 0.05, height: small.height / 0.05))
            }
        }
    }

    // MARK: Rendering

    private func renderImage(_ recipe: EditRecipe, scale: CGFloat) async -> UIImage? {
        guard let source else { return nil }
        let analysis = self.analysis
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let image = PhotoRenderer.render(source, recipe: recipe, scale: scale, analysis: analysis),
                      let cg = PhotoRenderer.cgImage(image) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: cg))
            }
        }
    }

    private func scheduleRender() {
        generation += 1
        let current = generation
        let recipe = self.recipe
        Task {
            // Wait a moment so dragging a slider doesn't queue up dozens of renders.
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard current == generation else { return }
            let image = await renderImage(recipe, scale: previewScale)
            if current == generation, let image { preview = image }
        }
    }

    private func makeLookThumbnails() async {
        let thumbScale = previewScale * 0.12
        for look in Look.all {
            var recipe = EditRecipe()
            recipe.look = look.id
            recipe.aspect = .square
            if let image = await renderImage(recipe, scale: thumbScale) {
                lookThumbnails[look.id] = image
            }
        }
    }

    func reset() {
        recipe = EditRecipe()
    }

    // MARK: Saving

    /// Saves a full-resolution copy to Photos (the original stays as it was).
    func save() async -> Bool {
        guard let data = await fullResolutionHEIC() else {
            message = "Couldn't create the edited photo."
            return false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Lumen can't save to Photos. Allow it in Settings → Lumen → Photos."
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes the full-resolution edit to a file for the share sheet.
    func prepareShare() async {
        guard let data = await fullResolutionHEIC() else {
            message = "Couldn't create the edited photo."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen \(Self.stamp()).heic")
        do {
            try data.write(to: url)
            shareURL = url
        } catch {
            message = "Couldn't prepare the photo to share."
        }
    }

    private func fullResolutionHEIC() async -> Data? {
        guard let source else { return nil }
        saving = true
        defer { saving = false }
        let recipe = self.recipe
        let analysis = self.analysis
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let image = PhotoRenderer.render(source, recipe: recipe, scale: 1, analysis: analysis) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PhotoRenderer.heic(image))
            }
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}
