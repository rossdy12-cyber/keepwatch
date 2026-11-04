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
    @Published var upscaler = UpscalerSettings.load() {
        didSet { upscaler.save() }
    }
    @Published private(set) var upscaling = false
    @Published private(set) var upscaleStatus = ""
    @Published private(set) var upscaleProgress: Double = 0
    @Published private(set) var imageSize: CGSize = .zero
    private var upscaleTask: Task<Void, Never>?

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
        await prepare()
    }

    /// Previews, AI analysis and look thumbnails for the current source.
    private func prepare() async {
        guard let source else { return }
        let fullSize = await Self.extent(of: source)
        imageSize = fullSize.size
        let longest = max(fullSize.width, fullSize.height)
        previewScale = longest > 0 ? min(1, 1800 / longest) : 1
        original = await renderImage(EditRecipe(), scale: previewScale)
        preview = original
        loading = false
        await analyse()
        await makeLookThumbnails()
    }

    // MARK: AI upscaling on the NAS

    /// Sends the photo (with the edits so far) to the NAS, then carries on editing the bigger version.
    func upscale(scale: Int) {
        guard !upscaling, source != nil else { return }
        upscaleTask = Task { await runUpscale(scale: scale) }
    }

    func cancelUpscale() {
        upscaleTask?.cancel()
        upscaleTask = nil
        upscaling = false
        upscaleStatus = ""
    }

    private func runUpscale(scale: Int) async {
        let client = UpscaleClient(settings: upscaler)
        upscaling = true
        upscaleProgress = 0
        upscaleStatus = "Preparing…"
        defer {
            upscaling = false
            if !Task.isCancelled { upscaleStatus = "" }
        }
        do {
            // Send it at the size the NAS will work at (it shrinks bigger photos anyway): a much smaller upload.
            let limit = await client.inputLimit(scale: scale)
            let megapixels = imageSize.width * imageSize.height / 1_000_000
            let sendScale = megapixels > limit ? CGFloat((limit / megapixels).squareRoot()) : 1
            guard let jpeg = await renderJPEG(scale: sendScale) else { throw UpscaleError.server("Couldn't prepare the photo.") }
            upscaleStatus = "Uploading…"
            let job = try await client.start(jpeg: jpeg, scale: scale)
            var status = try await client.status(job)
            while status.state == "queued" || status.state == "working" {
                try Task.checkCancellation()
                upscaleProgress = status.progress
                upscaleStatus = status.state == "queued"
                    ? (status.queuePosition > 1 ? "Waiting (\(status.queuePosition - 1) ahead)…" : "Starting…")
                    : "Upscaling \(scale)× on \(Self.processorName(status.processor))… \(Int(status.progress * 100))%"
                try await Task.sleep(nanoseconds: 1_000_000_000)
                status = try await client.status(job)
            }
            guard status.state == "done" else { throw UpscaleError.server(status.error ?? "The upscale failed.") }
            upscaleStatus = "Downloading…"
            let data = try await client.result(job)
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw UpscaleError.server("The upscaled photo couldn't be opened.")
            }
            // The edits are now part of the photo: carry on from the bigger version with fresh sliders.
            source = .image(image)
            isRAW = false
            analysis = nil
            recipe = EditRecipe()
            await prepare()
            message = "Upscaled to \(Int(image.extent.width)) × \(Int(image.extent.height)). Tap Save to keep it."
        } catch is CancellationError {
            message = "Upscale cancelled."
        } catch {
            message = error.localizedDescription
        }
    }

    /// "GPU (DESKTOP-ABC)" -> "your PC's GPU (DESKTOP-ABC)"; anything else -> "your NAS".
    private static func processorName(_ processor: String?) -> String {
        guard let processor, processor.hasPrefix("GPU") else { return "your NAS" }
        return "your PC's " + processor
    }

    private func renderJPEG(scale: CGFloat) async -> Data? {
        guard let source else { return nil }
        let recipe = self.recipe
        let analysis = self.analysis
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let image = PhotoRenderer.render(source, recipe: recipe, scale: scale, analysis: analysis),
                      let cg = PhotoRenderer.cgImage(image) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: cg).jpegData(compressionQuality: 0.95))
            }
        }
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
