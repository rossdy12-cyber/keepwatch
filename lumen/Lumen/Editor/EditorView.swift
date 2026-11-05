import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable {
    case looks = "Looks", ai = "AI", light = "Light", colour = "Colour", grade = "Grade", detail = "Detail", selective = "Masks", crop = "Crop"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .looks: return "camera.filters"
        case .ai: return "wand.and.stars"
        case .light: return "sun.max"
        case .colour: return "thermometer.medium"
        case .grade: return "paintpalette"
        case .detail: return "triangle"
        case .selective: return "circle.lefthalf.striped.horizontal"
        case .crop: return "crop.rotate"
        }
    }
}

struct EditorView: View {
    let source: EditSource
    @StateObject private var model = EditorModel()
    @Environment(\.dismiss) private var dismiss
    @State private var tool: EditorTool = .looks
    @State private var selectedMaskID: String?
    @State private var showRemove = false
    @State private var removeImage: UIImage?
    @State private var showOriginal = false
    @State private var savedBanner = false
    @State private var confirmClose = false
    @State private var showLUTImporter = false
    @State private var lutError: String?
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                Color.black
                if let image = showOriginal ? model.original : model.preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else if model.loading {
                    ProgressView().tint(.white)
                }
                if tool == .selective, !showOriginal, let id = selectedMaskID, let bind = maskBinding(id) {
                    MaskOverlay(mask: bind, imageSize: model.imageSize)
                }
                VStack {
                    if showOriginal {
                        Text("ORIGINAL").font(.caption2.weight(.heavy)).padding(6)
                            .background(Color.black.opacity(0.6), in: Capsule())
                    }
                    Spacer()
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
            // Press and hold to compare with the original.
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { pressing in
                showOriginal = pressing
            }, perform: {})
            toolPanel
                .frame(height: 230)
            toolBar
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task {
            await model.load(source)
            if let scale = source.autoUpscale { model.upscale(scale: scale) }
        }
        .sheet(item: Binding(get: { model.shareURL.map(ShareItem.init) }, set: { if $0 == nil { model.shareURL = nil } })) { item in
            ActivitySheet(items: [item.url])
        }
        .fullScreenCover(isPresented: $showRemove) {
            if let removeImage {
                RemoveObjectsView(image: removeImage) { strokes, brush in
                    model.removeObjects(strokes: strokes, brush: brush, pixelSize: removeImage.size)
                }
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
        .fileImporter(isPresented: $showLUTImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let id = try LUTStore.importLUT(from: url)
                    model.reloadLUTs()
                    model.recipe.look = id
                    if model.recipe.lookAmount == 0 { model.recipe.lookAmount = 1 }
                } catch {
                    lutError = error.localizedDescription
                }
            case .failure(let error):
                lutError = error.localizedDescription
            }
        }
        .alert("Couldn't import that LUT", isPresented: Binding(get: { lutError != nil }, set: { if !$0 { lutError = nil } })) {
            Button("OK", role: .cancel) { lutError = nil }
        } message: {
            Text(lutError ?? "")
        }
        .sheet(isPresented: $showExport) {
            ExportOptionsSheet(options: $model.export)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if model.recipe.isUntouched { dismiss() } else { confirmClose = true }
            } label: {
                Image(systemName: "xmark").font(.headline)
            }
            Spacer()
            if model.isRAW {
                Text("RAW").font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.yellow))
                    .foregroundStyle(.yellow)
            }
            Spacer()
            Button("Reset") { model.reset() }
                .disabled(model.recipe.isUntouched)
            Button { showExport = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .padding(.leading, 12)
            Button {
                Task { await model.prepareShare() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .padding(.horizontal, 12)
            .disabled(model.loading || model.saving)
            Button {
                Task {
                    if await model.save() {
                        savedBanner = true
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        savedBanner = false
                    }
                }
            } label: {
                if model.saving {
                    ProgressView().tint(.yellow)
                } else {
                    Text("Save").fontWeight(.bold).foregroundStyle(.yellow)
                }
            }
            .disabled(model.loading || model.saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var toolPanel: some View {
        switch tool {
        case .looks:
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Look.catalog) { look in
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
                                    Text(look.name)
                                        .font(.caption2.weight(model.recipe.look == look.id ? .bold : .regular))
                                        .foregroundStyle(model.recipe.look == look.id ? .yellow : .white)
                                        .lineLimit(1).frame(width: 72)
                                }
                            }
                            .contextMenu {
                                if LUTStore.isCustom(look.id) {
                                    Button(role: .destructive) {
                                        if model.recipe.look == look.id { model.recipe.look = Look.none.id }
                                        LUTStore.delete(id: look.id)
                                        model.reloadLUTs()
                                    } label: { Label("Delete LUT", systemImage: "trash") }
                                }
                            }
                        }
                        Button { showLUTImporter = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.title3)
                                    .frame(width: 72, height: 72)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                Text("Import LUT").font(.caption2).foregroundStyle(.white)
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
                    ForEach(Adjustment.ai) { adjustment in
                        let needsSubject = adjustment.id == "subjectPop" || adjustment.id == "backgroundBlur"
                        AdjustmentRow(name: adjustment.name, value: $model.recipe[dynamicMember: adjustment.keyPath],
                                      range: adjustment.range, neutral: 0)
                            .disabled(needsSubject && !model.hasSubject)
                            .opacity(needsSubject && !model.hasSubject ? 0.4 : 1)
                    }
                    Text(model.analysing ? "Looking for the subject…"
                         : model.hasSubject ? "Done on your iPhone: nothing is uploaded."
                         : "No clear subject found, so Subject pop and Background blur are off for this photo.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    upscaleSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        case .light:
            adjustmentList(Adjustment.light)
        case .colour:
            adjustmentList(Adjustment.colour)
        case .grade:
            gradePanel
        case .detail:
            adjustmentList(Adjustment.detail)
        case .selective:
            selectivePanel
        case .crop:
            VStack(spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CropAspect.allCases) { aspect in
                            Button { model.recipe.aspect = aspect } label: {
                                Text(aspect.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(model.recipe.aspect == aspect ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                                    .foregroundStyle(model.recipe.aspect == aspect ? .black : .white)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                AdjustmentRow(name: "Straighten", value: $model.recipe.straighten, range: -15...15, neutral: 0, format: "%+.1f°")
                    .padding(.horizontal, 16)
            }
            .padding(.top, 16)
        }
    }

    /// AI upscaling on the NAS (the lumen-ai app on TrueNAS).
    private var upscaleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.white.opacity(0.2))
            Text("AI upscale on your NAS").font(.subheadline.weight(.semibold))
            if model.upscaling {
                ProgressView(value: model.upscaleProgress).tint(.yellow)
                HStack {
                    Text(model.upscaleStatus).font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button("Cancel") { model.cancelUpscale() }.font(.caption.weight(.semibold))
                }
            } else if model.inpainting {
                ProgressView(value: model.inpaintProgress).tint(.yellow)
                HStack {
                    Text(model.inpaintStatus).font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button("Cancel") { model.cancelInpaint() }.font(.caption.weight(.semibold))
                }
            } else if model.upscaler.isConfigured {
                Button {
                    Task {
                        removeImage = await model.prepareRemoval()
                        if removeImage != nil { showRemove = true }
                    }
                } label: {
                    Label("Remove objects", systemImage: "wand.and.stars.inverse")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
                .disabled(model.loading)
                HStack(spacing: 10) {
                    ForEach([2, 4], id: \.self) { scale in
                        Button { model.upscale(scale: scale) } label: {
                            Text("Upscale \(scale)×")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .disabled(model.loading)
                Text("Real-ESRGAN rebuilds fine detail as it enlarges. With your PC's GPU worker online it takes seconds and allows bigger photos; otherwise the NAS's processor does it in a few minutes. Your edits so far are included.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            DisclosureGroup(model.upscaler.isConfigured ? "Upscaler settings" : "Set up the upscaler") {
                VStack(spacing: 8) {
                    TextField("http://100.85.127.42:10702", text: $model.upscaler.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Key (from the lumen-ai app's logs)", text: $model.upscaler.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            .font(.caption)
            .tint(.yellow)
        }
    }

    // MARK: Colour grading

    private var gradePanel: some View {
        ScrollView {
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ColorWheelView(title: "Shadows",
                                       x: $model.recipe.grade.shadows.x,
                                       y: $model.recipe.grade.shadows.y,
                                       luma: $model.recipe.grade.shadows.luma)
                        ColorWheelView(title: "Midtones",
                                       x: $model.recipe.grade.midtones.x,
                                       y: $model.recipe.grade.midtones.y,
                                       luma: $model.recipe.grade.midtones.luma)
                        ColorWheelView(title: "Highlights",
                                       x: $model.recipe.grade.highlights.x,
                                       y: $model.recipe.grade.highlights.y,
                                       luma: $model.recipe.grade.highlights.luma)
                    }
                    .padding(.horizontal, 16)
                }
                Text("Drag each wheel to push colour into the darks, mids and brights; the slider under each sets that range's brightness. Great for film looks and matching shots.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 14)
        }
    }

    // MARK: Selective (local) edits

    private var selectivePanel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { addMask(.radial) } label: { maskChip("Radial", "plus.circle") }
                    Button { addMask(.linear) } label: { maskChip("Graduated", "plus.circle") }
                    ForEach(Array(model.recipe.masks.enumerated()), id: \.element.id) { index, mask in
                        Button { selectedMaskID = mask.id } label: {
                            Text("\(mask.kind.rawValue) \(index + 1)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(selectedMaskID == mask.id ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(selectedMaskID == mask.id ? .black : .white)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            if let id = selectedMaskID, let bind = maskBinding(id) {
                ScrollView {
                    VStack(spacing: 10) {
                        HStack {
                            Toggle("Invert", isOn: bind.invert).font(.subheadline).tint(.yellow)
                            Spacer()
                            Button(role: .destructive) { deleteMask(id) } label: { Label("Delete", systemImage: "trash") }
                                .font(.subheadline)
                        }
                        ForEach(MaskLayer.adjustments, id: \.name) { adj in
                            AdjustmentRow(name: adj.name, value: bind[dynamicMember: adj.keyPath], range: adj.range, neutral: 0)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                Text("Add a radial or graduated mask, drag it on the photo, then adjust just that area.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
        }
        .padding(.top, 12)
    }

    private func maskChip(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
    }

    private func addMask(_ kind: MaskLayer.Kind) {
        let mask = MaskLayer.new(kind)
        model.recipe.masks.append(mask)
        selectedMaskID = mask.id
    }

    private func deleteMask(_ id: String) {
        model.recipe.masks.removeAll { $0.id == id }
        selectedMaskID = model.recipe.masks.last?.id
    }

    private func maskBinding(_ id: String) -> Binding<MaskLayer>? {
        guard model.recipe.masks.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.recipe.masks.first(where: { $0.id == id }) ?? MaskLayer.new(.radial) },
            set: { newValue in
                if let i = model.recipe.masks.firstIndex(where: { $0.id == id }) { model.recipe.masks[i] = newValue }
            })
    }

    private func adjustmentList(_ adjustments: [Adjustment]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(adjustments) { adjustment in
                    AdjustmentRow(name: adjustment.name, value: $model.recipe[dynamicMember: adjustment.keyPath],
                                  range: adjustment.range, neutral: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var toolBar: some View {
        HStack {
            ForEach(EditorTool.allCases) { item in
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
}

/// One editing slider: name, value, slider. Double-tap the name to reset it.
struct AdjustmentRow: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var format: String = "%+.0f"

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                Text(displayValue)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(value == neutral ? .white.opacity(0.5) : .yellow)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = neutral }
            Slider(value: $value, in: range)
                .tint(.yellow)
        }
    }

    private var displayValue: String {
        if format != "%+.0f" { return String(format: format, value) }
        // Shown as -100…100 (or 0…100), like most photo editors.
        let span = max(abs(range.lowerBound), abs(range.upperBound))
        let scaled = span > 0 ? value / span * 100 : value
        return range.lowerBound < 0 ? String(format: "%+.0f", scaled) : String(format: "%.0f", scaled)
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The iOS share sheet.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
