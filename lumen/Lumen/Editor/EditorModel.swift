import CoreImage
import ImageIO
import Photos
import UIKit

/// What to edit: a photo just taken (by its Photos ID) or one picked from the library (its data).
struct EditSource: Identifiable {
    let id = UUID()
    var data: Data?
    var assetID: String?
    var videoURL: URL?
    /// Start an AI upscale (2 or 4) as soon as the photo opens.
    var autoUpscale: Int?

    init(data: Data) { self.data = data }
    init(assetID: String, autoUpscale: Int? = nil) {
        self.assetID = assetID
        self.autoUpscale = autoUpscale
    }
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
    @Published var export = ExportOptions.load() {
        didSet { export.save() }
    }
    @Published private(set) var upscaling = false
    @Published private(set) var upscaleStatus = ""
    @Published private(set) var upscaleProgress: Double = 0
    @Published private(set) var imageSize: CGSize = .zero
    private var upscaleTask: Task<Void, Never>?
    @Published private(set) var inpainting = false
    @Published private(set) var inpaintStatus = ""
    @Published private(set) var inpaintProgress: Double = 0
    /// The JPEG the object-removal canvas is painting on (and what we send to the NAS).
    private var inpaintImageData: Data?
    private var inpaintTask: Task<Void, Never>?

    private var source: PhotoSource?
    /// The person cut-out recorded with Portrait photos (better than guessing).
    private var portraitMatte: CIImage?
    /// The original's camera details (EXIF, location), written into saved and shared copies.
    private var metadata: [String: Any] = [:]
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
        portraitMatte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true, .applyOrientationProperty: true])
        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            metadata = properties
        }
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
    // MARK: AI object removal on the NAS

    /// Renders the current edit (without crop/straighten) for the removal canvas, and remembers it to send.
    func prepareRemoval() async -> UIImage? {
        guard let source else { return nil }
        var recipe = self.recipe
        recipe.aspect = .original
        recipe.straighten = 0
        let analysis = self.analysis
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let image = PhotoRenderer.render(source, recipe: recipe, scale: 1, analysis: analysis),
                      let cg = PhotoRenderer.cgImage(image) else {
                    continuation.resume(returning: nil)
                    return
                }
                let ui = UIImage(cgImage: cg)
                let data = ui.jpegData(compressionQuality: 0.95)
                Task { @MainActor in self.inpaintImageData = data }
                continuation.resume(returning: ui)
            }
        }
    }

    /// Sends the painted mask (normalised strokes) to the NAS, then carries on from the cleaned-up photo.
    func removeObjects(strokes: [[CGPoint]], brush: Double, pixelSize: CGSize) {
        guard !inpainting, let jpeg = inpaintImageData, !strokes.isEmpty else { return }
        inpaintTask = Task { await runInpaint(jpeg: jpeg, strokes: strokes, brush: brush, size: pixelSize) }
    }

    func cancelInpaint() {
        inpaintTask?.cancel()
        inpaintTask = nil
        inpainting = false
        inpaintStatus = ""
    }

    private func runInpaint(jpeg: Data, strokes: [[CGPoint]], brush: Double, size: CGSize) async {
        inpainting = true
        inpaintProgress = 0
        inpaintStatus = "Preparing…"
        defer {
            inpainting = false
            if !Task.isCancelled { inpaintStatus = "" }
        }
        do {
            let width = Int(size.width), height = Int(size.height)
            guard let mask = Self.maskPNG(strokes: strokes, brush: brush, width: width, height: height) else {
                throw UpscaleError.server("Couldn't build the mask.")
            }
            let client = UpscaleClient(settings: upscaler)
            inpaintStatus = "Uploading…"
            let job = try await client.startInpaint(image: jpeg, mask: mask)
            var status = try await client.status(job)
            while status.state == "queued" || status.state == "working" {
                try Task.checkCancellation()
                inpaintProgress = status.progress
                inpaintStatus = status.state == "queued"
                    ? "Waiting…"
                    : "Removing on \(Self.processorName(status.processor))… \(Int(status.progress * 100))%"
                try await Task.sleep(nanoseconds: 1_000_000_000)
                status = try await client.status(job)
            }
            guard status.state == "done" else { throw UpscaleError.server(status.error ?? "The removal failed.") }
            inpaintStatus = "Downloading…"
            let data = try await client.result(job)
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw UpscaleError.server("The cleaned-up photo couldn't be opened.")
            }
            source = .image(image)
            isRAW = false
            analysis = nil
            inpaintImageData = nil
            recipe = EditRecipe()
            await prepare()
            message = "Objects removed. Tap Save to keep it."
        } catch is CancellationError {
            message = "Removal cancelled."
        } catch {
            message = error.localizedDescription
        }
    }

    /// A black image with the brushed strokes in white (white = remove), at the photo's pixel size.
    private static func maskPNG(strokes: [[CGPoint]], brush: Double, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let radius = max(2, CGFloat(brush) * min(w, h))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let image = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(radius * 2)
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                if stroke.count == 1 {
                    ctx.fillEllipse(in: CGRect(x: first.x * w - radius, y: first.y * h - radius, width: radius * 2, height: radius * 2))
                    continue
                }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: first.x * w, y: first.y * h))
                for point in stroke.dropFirst() { ctx.addLine(to: CGPoint(x: point.x * w, y: point.y * h)) }
                ctx.strokePath()
            }
        }
        return image.pngData()
    }

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
        var found = result
        if let portraitMatte { found.subjectMask = portraitMatte }
        analysis = found
        hasSubject = found.hasSubject
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
        for look in Look.catalog {
            var recipe = EditRecipe()
            recipe.look = look.id
            recipe.aspect = .square
            if let image = await renderImage(recipe, scale: thumbScale) {
                lookThumbnails[look.id] = image
            }
        }
    }

    /// After importing or deleting a LUT: refresh the look list and rebuild thumbnails.
    func reloadLUTs() {
        Task { await makeLookThumbnails() }
    }

    // MARK: Privacy blur

    @Published var blurStyle: BlurRegion.Style = .pixelate
    @Published private(set) var detectingBlur = false

    /// Finds faces (or text/plates) and adds a blur region over each one it doesn't already cover.
    func addAutoBlur(text: Bool) {
        guard let source, !detectingBlur else { return }
        detectingBlur = true
        var base = recipe
        base.aspect = .original
        base.straighten = 0
        base.blurs = []
        let analysis = self.analysis
        let style = blurStyle
        Task {
            let image: CIImage? = await withCheckedContinuation { continuation in
                renderQueue.async {
                    continuation.resume(returning: PhotoRenderer.render(source, recipe: base, scale: 0.7, analysis: analysis))
                }
            }
            guard let image else { detectingBlur = false; return }
            let rects = text ? await AutoBlur.text(in: image) : await AutoBlur.faces(in: image)
            var added = 0
            for rect in rects where rect.width > 0.01 && rect.height > 0.01 {
                if !recipe.blurs.contains(where: { $0.rect.intersects(rect) }) {
                    recipe.blurs.append(BlurRegion.make(rect, style: style))
                    added += 1
                }
            }
            detectingBlur = false
            if added == 0 { message = text ? "No text found to blur." : "No faces found." }
        }
    }

    func removeBlur(_ id: String) { recipe.blurs.removeAll { $0.id == id } }
    func clearBlurs() { recipe.blurs.removeAll() }

    // MARK: Copy / paste edits (non-destructive)

    @Published var hasCopiedRecipe = RecipeClipboard.hasValue

    /// Copies this photo's look (tone, colour, grade, look) to reuse on other photos.
    func copyEdits() {
        RecipeClipboard.copy(recipe)
        hasCopiedRecipe = true
        message = "Edits copied. Open another photo and tap Paste."
    }

    /// Applies the copied edits, keeping this photo's own crop and local (mask/blur) adjustments.
    func pasteEdits() {
        guard var copied = RecipeClipboard.stored else { return }
        copied.aspect = recipe.aspect
        copied.straighten = recipe.straighten
        copied.masks = recipe.masks
        copied.blurs = recipe.blurs
        recipe = copied
    }

    func reset() {
        recipe = EditRecipe()
    }

    // MARK: Saving

    /// Saves a full-resolution copy to Photos (the original stays as it was).
    func save() async -> Bool {
        guard let data = await exportData() else {
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

    /// Writes the full-resolution edit to a file for the share sheet, in the chosen export format.
    func prepareShare() async {
        guard let data = await exportData() else {
            message = "Couldn't create the edited photo."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen \(Self.stamp()).\(export.format.ext)")
        do {
            try data.write(to: url)
            shareURL = url
        } catch {
            message = "Couldn't prepare the photo to share."
        }
    }

    /// Renders and encodes the finished photo using the current export options.
    private func exportData() async -> Data? {
        guard let source else { return nil }
        saving = true
        defer { saving = false }
        let recipe = self.recipe
        let analysis = self.analysis
        let options = self.export
        var properties = metadata
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if options.stripMetadata {
            properties = [kCGImagePropertyOrientation as String: 1]
        } else if options.stripLocation {
            properties.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
        }
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                guard let image = PhotoRenderer.render(source, recipe: recipe, scale: 1, analysis: analysis) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PhotoRenderer.encode(image, options: options, properties: properties))
            }
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}
