import AVFoundation
import AVKit
import CoreImage
import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from the library, copied somewhere Lumen can read it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Edits a video: the same looks, AI enhance, light, colour and detail as photos, previewed live while it plays.
@MainActor
final class VideoEditorModel: ObservableObject {
    @Published var recipe = EditRecipe() {
        didSet { if recipe != oldValue { scheduleUpdate() } }
    }
    @Published private(set) var lookThumbnails: [String: UIImage] = [:]
    @Published private(set) var analysing = true
    @Published private(set) var exporting = false
    @Published private(set) var progress: Double = 0
    @Published var message: String?

    let player = AVPlayer()
    private let asset: AVURLAsset
    private let item: AVPlayerItem
    private var analysis: AIAnalysis?
    private var generation = 0
    private var loopObserver: NSObjectProtocol?

    init(url: URL) {
        asset = AVURLAsset(url: url)
        item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.isMuted = false
        loopObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
    }

    func load() async {
        // Work out Magic Enhance from a frame a little way in (the very first is often black).
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let time = CMTime(seconds: min(1, duration / 3), preferredTimescale: 600)
        if let frame = try? await generator.image(at: time).image {
            let image = CIImage(cgImage: frame)
            analysis = AIAnalysis(autoFilters: AIAnalyser.autoFilters(for: image), subjectMask: nil)
            makeThumbnails(from: image)
        } else {
            analysis = AIAnalysis()
        }
        analysing = false
        await updateComposition()
        player.play()
    }

    func magicEnhance() {
        var updated = recipe
        updated.autoEnhance = 1
        updated.clarity = max(updated.clarity, 0.1)
        recipe = updated
    }

    func reset() { recipe = EditRecipe() }

    func stop() { player.pause() }

    private func makeThumbnails(from frame: CIImage) {
        let side = min(frame.extent.width, frame.extent.height)
        let square = frame.cropped(to: CGRect(x: frame.extent.midX - side / 2, y: frame.extent.midY - side / 2, width: side, height: side))
        let scale = 160 / side
        let small = square.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        for look in Look.all {
            var recipe = EditRecipe()
            recipe.look = look.id
            let output = PhotoRenderer.renderVideoFrame(small, recipe: recipe, analysis: nil)
            if let cg = PhotoRenderer.cgImage(output) { lookThumbnails[look.id] = UIImage(cgImage: cg) }
        }
    }

    private func scheduleUpdate() {
        generation += 1
        let current = generation
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard current == generation else { return }
            await updateComposition()
        }
    }

    private func makeComposition() async throws -> AVVideoComposition {
        let recipe = self.recipe
        let analysis = self.analysis
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            let output = PhotoRenderer.renderVideoFrame(request.sourceImage, recipe: recipe, analysis: analysis)
            request.finish(with: output, context: nil)
        }
    }

    private func updateComposition() async {
        do {
            item.videoComposition = try await makeComposition()
        } catch {
            message = "Couldn't preview the edit: \(error.localizedDescription)"
        }
    }

    // MARK: Saving

    func save() async -> Bool {
        exporting = true
        progress = 0
        defer { exporting = false }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            message = "This video can't be exported."
            return false
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-\(UUID().uuidString).mov")
        do {
            session.videoComposition = try await makeComposition()
        } catch {
            message = "Couldn't apply the edit: \(error.localizedDescription)"
            return false
        }
        session.outputURL = url
        session.outputFileType = .mov
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                progress = Double(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await session.export()
        watcher.cancel()
        guard session.status == .completed else {
            message = "Export failed: \(session.error?.localizedDescription ?? "unknown error")"
            return false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Lumen can't save to Photos. Allow it in Settings → Lumen → Photos."
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            try? FileManager.default.removeItem(at: url)
            return true
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }
}

struct VideoEditorView: View {
    @StateObject private var model: VideoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var tool: EditorTool = .looks
    @State private var savedBanner = false
    @State private var confirmClose = false

    init(url: URL) {
        _model = StateObject(wrappedValue: VideoEditorModel(url: url))
    }

    private let tools: [EditorTool] = [.looks, .ai, .light, .colour, .detail]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if model.recipe.isUntouched { close() } else { confirmClose = true }
                } label: { Image(systemName: "xmark").font(.headline) }
                Spacer()
                Text("VIDEO").font(.caption2.weight(.heavy)).foregroundStyle(.yellow)
                Spacer()
                Button("Reset") { model.reset() }.disabled(model.recipe.isUntouched)
                Button {
                    Task {
                        if await model.save() {
                            savedBanner = true
                            try? await Task.sleep(nanoseconds: 1_800_000_000)
                            savedBanner = false
                        }
                    }
                } label: {
                    Text("Save").fontWeight(.bold).foregroundStyle(.yellow)
                }
                .padding(.leading, 12)
                .disabled(model.exporting || model.analysing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ZStack {
                VideoPlayer(player: model.player)
                VStack {
                    Spacer()
                    if model.exporting {
                        VStack(spacing: 6) {
                            ProgressView(value: model.progress).tint(.yellow).frame(width: 180)
                            Text("Saving video… \(Int(model.progress * 100))%").font(.caption)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let message = model.message {
                        Text(message).font(.footnote).padding(8)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .onTapGesture { model.message = nil }
                    }
                    if savedBanner {
                        Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold)).padding(8)
                            .background(Color.black.opacity(0.7), in: Capsule())
                    }
                }
                .padding(10)
            }

            panel.frame(height: 230)

            HStack {
                ForEach(tools) { item in
                    Button { tool = item } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 18))
                            Text(item.rawValue).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(tool == item ? .yellow : .white.opacity(0.75))
                    }
                }
            }
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .confirmationDialog("Discard your changes?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { close() }
        }
    }

    private func close() {
        model.stop()
        dismiss()
    }

    @ViewBuilder
    private var panel: some View {
        switch tool {
        case .looks:
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Look.all) { look in
                            Button {
                                model.recipe.look = look.id
                                if model.recipe.lookAmount == 0 { model.recipe.lookAmount = 1 }
                            } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if let thumb = model.lookThumbnails[look.id] {
                                            Image(uiImage: thumb).resizable().scaledToFill()
                                        } else {
                                            Color.white.opacity(0.08)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(model.recipe.look == look.id ? Color.yellow : .clear, lineWidth: 2))
                                    Text(look.name).font(.caption2)
                                        .foregroundStyle(model.recipe.look == look.id ? .yellow : .white)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if model.recipe.look != Look.none.id {
                    AdjustmentRow(name: "Strength", value: $model.recipe.lookAmount, range: 0...1, neutral: 1)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 14)
        case .ai:
            ScrollView {
                VStack(spacing: 12) {
                    Button { model.magicEnhance() } label: {
                        Label(model.analysing ? "Analysing…" : "Magic Enhance", systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.black)
                    }
                    .disabled(model.analysing)
                    AdjustmentRow(name: "Magic Enhance", value: $model.recipe.autoEnhance, range: 0...1)
                    AdjustmentRow(name: "Reduce noise", value: $model.recipe.noiseReduction, range: 0...1)
                    Text("Subject pop and background blur are for photos only.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        case .light:
            list(Adjustment.light)
        case .colour:
            list(Adjustment.colour)
        default:
            list(Adjustment.detail)
        }
    }

    private func list(_ adjustments: [Adjustment]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(adjustments) { adjustment in
                    AdjustmentRow(name: adjustment.name, value: $model.recipe[dynamicMember: adjustment.keyPath], range: adjustment.range)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
