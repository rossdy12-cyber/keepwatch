import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CameraView: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var level = LevelMonitor()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("lumen.grid") private var showGrid = true
    @AppStorage("lumen.histogram") private var showHistogram = true
    @AppStorage("lumen.level") private var showLevel = true
    @State private var timer = 0
    @State private var countdown: Int?
    @State private var control: ProControl?
    @State private var focusPoint: CGPoint?
    @State private var flashOverlay = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var editing: EditSource?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorised {
                cameraScreen
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("Lumen needs the camera").font(.headline)
                    Text("Allow it in Settings → Lumen → Camera.").foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            camera.start()
            level.start()
        }
        .onDisappear {
            camera.stop()
            level.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        editing = EditSource(videoURL: movie.url)
                    } else {
                        camera.message = "Couldn't open that video."
                    }
                } else if let data = try? await item.loadTransferable(type: Data.self) {
                    editing = EditSource(data: data)
                }
                libraryItem = nil
            }
        }
        .fullScreenCover(item: $editing) { source in
            if let url = source.videoURL {
                VideoEditorView(url: url)
            } else {
                EditorView(source: source)
            }
        }
    }

    // MARK: Layout

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                CameraPreview(camera: camera) { point in
                    focusPoint = point
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if focusPoint == point { focusPoint = nil }
                    }
                }
                if showGrid { GridOverlay() }
                if showLevel { LevelOverlay(level: level) }
                if let focusPoint {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(focusPoint)
                        .allowsHitTesting(false)
                }
                VStack {
                    HStack(alignment: .top) {
                        readout
                        Spacer()
                        if showHistogram { HistogramView(bins: camera.histogram) }
                    }
                    Spacer()
                    if let countdown {
                        Text("\(countdown)")
                            .font(.system(size: 96, weight: .thin, design: .rounded))
                            .shadow(radius: 8)
                        Spacer()
                    }
                    if let message = camera.message {
                        Text(message)
                            .font(.footnote)
                            .padding(8)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            .onTapGesture { camera.message = nil }
                    }
                    if camera.zoom > 1.05 {
                        Text(String(format: "%.1f×", camera.zoom))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.black.opacity(0.5), in: Capsule())
                    }
                }
                .padding(10)
                if flashOverlay {
                    Color.black.opacity(0.8).allowsHitTesting(false)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            Spacer(minLength: 0)
            proControls
            lensPicker
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 22) {
            if camera.flashAvailable {
                Button { cycleFlash() } label: {
                    Image(systemName: flashIcon)
                        .foregroundStyle(camera.flash == .off ? .white : .yellow)
                }
                .accessibilityLabel("Flash")
            }
            Menu {
                ForEach(CaptureFormat.allCases) { format in
                    if (format != .raw && format != .rawPlusHEIF) || camera.rawAvailable {
                        Button {
                            camera.format = format
                        } label: {
                            Label(formatLabel(format), systemImage: camera.format == format ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Text(camera.format == .raw && camera.proRAW ? "ProRAW" : camera.format.rawValue)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white, lineWidth: 1))
            }
            Button { timer = timer == 0 ? 3 : (timer == 3 ? 10 : 0) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "timer")
                    if timer > 0 { Text("\(timer)s").font(.caption.weight(.semibold)) }
                }
                .foregroundStyle(timer > 0 ? .yellow : .white)
            }
            .accessibilityLabel("Self-timer")
            Menu {
                Toggle("Grid", isOn: $showGrid)
                Toggle("Level", isOn: $showLevel)
                Toggle("Histogram", isOn: $showHistogram)
            } label: {
                Image(systemName: "square.grid.3x3")
            }
        }
        .font(.system(size: 18))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// The settings in use: what the camera chose in auto, or what you set.
    private var readout: some View {
        HStack(spacing: 8) {
            Text("ISO \(Int(camera.iso))")
            Text(Self.shutterText(camera.shutter))
            if abs(camera.exposureBias) > 0.05 { Text(String(format: "%+.1f EV", camera.exposureBias)) }
            Text("\(Int(camera.temperature))K")
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.black.opacity(0.35), in: Capsule())
        .allowsHitTesting(false)
    }

    private var proControls: some View {
        VStack(spacing: 6) {
            if let control {
                controlSlider(control)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                ForEach(ProControl.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { control = control == item ? nil : item }
                    } label: {
                        Text(item.rawValue)
                            .font(.caption.weight(.bold))
                            .frame(width: 44, height: 26)
                            .background(control == item ? Color.yellow : Color.white.opacity(isManual(item) ? 0.3 : 0.12),
                                        in: Capsule())
                            .foregroundStyle(control == item ? .black : .white)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func controlSlider(_ control: ProControl) -> some View {
        switch control {
        case .ev:
            sliderRow(title: String(format: "%+.1f EV", camera.exposureBias), isAuto: abs(camera.exposureBias) < 0.05,
                      autoAction: { camera.setExposureBias(0) }) {
                Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float(($0 * 3).rounded() / 3)) }),
                       in: Double(max(camera.minBias, -3))...Double(min(camera.maxBias, 3)))
            }
        case .iso:
            sliderRow(title: "ISO \(Int(camera.iso))", isAuto: camera.autoExposure, autoAction: { camera.setAutoExposure(true) }) {
                Slider(value: Binding(get: { log2(Double(camera.iso)) }, set: { camera.setISO(Float(pow(2, $0))) }),
                       in: log2(Double(camera.minISO))...log2(Double(camera.maxISO)))
            }
        case .shutter:
            sliderRow(title: Self.shutterText(camera.shutter), isAuto: camera.autoExposure, autoAction: { camera.setAutoExposure(true) }) {
                Slider(value: Binding(get: { log2(camera.shutter) }, set: { camera.setShutter(pow(2, $0)) }),
                       in: log2(camera.minShutter)...log2(camera.maxShutter))
            }
        case .whiteBalance:
            sliderRow(title: "\(Int(camera.temperature))K  \(camera.tint >= 0 ? "+" : "")\(Int(camera.tint))",
                      isAuto: camera.autoWhiteBalance, autoAction: { camera.setAutoWhiteBalance(true) }) {
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { Double(camera.temperature) },
                                          set: { camera.setWhiteBalance(temperature: Float($0), tint: camera.tint) }), in: 2500...10000)
                        .tint(LinearGradient(colors: [.blue, .orange], startPoint: .leading, endPoint: .trailing))
                    Slider(value: Binding(get: { Double(camera.tint) },
                                          set: { camera.setWhiteBalance(temperature: camera.temperature, tint: Float($0)) }), in: -60...60)
                        .tint(LinearGradient(colors: [.green, .pink], startPoint: .leading, endPoint: .trailing))
                }
            }
        case .focus:
            sliderRow(title: camera.manualFocusSupported ? (camera.lensPosition < 0.05 ? "Near" : camera.lensPosition > 0.95 ? "Far" : String(format: "Focus %.0f%%", camera.lensPosition * 100)) : "Auto focus only",
                      isAuto: camera.autoFocus, autoAction: { camera.setAutoFocus(true) }) {
                Slider(value: Binding(get: { Double(camera.lensPosition) }, set: { camera.setLensPosition(Float($0)) }), in: 0...1)
                    .disabled(!camera.manualFocusSupported)
            }
        }
    }

    private func sliderRow<Content: View>(title: String, isAuto: Bool, autoAction: @escaping () -> Void,
                                          @ViewBuilder slider: () -> Content) -> some View {
        HStack(spacing: 10) {
            Button("AUTO", action: autoAction)
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(isAuto ? Color.yellow : Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isAuto ? .black : .white)
            slider()
                .tint(.yellow)
            Text(title)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 74, alignment: .trailing)
        }
    }

    private var lensPicker: some View {
        HStack(spacing: 10) {
            ForEach(camera.lenses.filter { $0.position == .back }) { lens in
                Button { camera.selectLens(lens) } label: {
                    Text(lens.label)
                        .font(.caption.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(camera.currentLensID == lens.id ? 0.25 : 0.08), in: Circle())
                        .foregroundStyle(camera.currentLensID == lens.id ? .yellow : .white)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                if let id = camera.lastAssetID { editing = EditSource(assetID: id) }
            } label: {
                Group {
                    if let thumb = camera.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Edit the last photo")
            .frame(maxWidth: .infinity)

            Button { shoot() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(camera.isCapturing ? Color.gray : Color.white).frame(width: 62, height: 62)
                }
            }
            .disabled(camera.isCapturing || countdown != nil)
            .accessibilityLabel("Take photo")

            HStack(spacing: 18) {
                PhotosPicker(selection: $libraryItem, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                    Image(systemName: "photo.on.rectangle")
                }
                .accessibilityLabel("Edit a photo or video from your library")
                Button { flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                }
                .accessibilityLabel("Switch camera")
            }
            .font(.title3)
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 18)
        .padding(.top, 4)
    }

    // MARK: Actions

    private func shoot() {
        if timer > 0 {
            countdown = timer
            Task { @MainActor in
                for remaining in stride(from: timer, to: 0, by: -1) {
                    countdown = remaining
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown = nil
                takePhoto()
            }
        } else {
            takePhoto()
        }
    }

    private func takePhoto() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashOverlay = true
        withAnimation(.easeOut(duration: 0.25)) { flashOverlay = false }
        camera.capture()
    }

    private func flipCamera() {
        let current = camera.lenses.first { $0.id == camera.currentLensID }
        if current?.position == .front {
            if let main = camera.lenses.first(where: { $0.label == "1×" }) { camera.selectLens(main) }
        } else if let front = camera.lenses.first(where: { $0.position == .front }) {
            camera.selectLens(front)
        }
    }

    private func cycleFlash() {
        switch camera.flash {
        case .off: camera.flash = .auto
        case .auto: camera.flash = .on
        default: camera.flash = .off
        }
    }

    private var flashIcon: String {
        switch camera.flash {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        default: return "bolt.slash.fill"
        }
    }

    private func formatLabel(_ format: CaptureFormat) -> String {
        switch format {
        case .heif: return "HEIF (small, high quality)"
        case .jpeg: return "JPEG (works everywhere)"
        case .raw: return camera.proRAW ? "ProRAW (most editing room)" : "RAW (DNG)"
        case .rawPlusHEIF: return camera.proRAW ? "ProRAW + HEIF" : "RAW + HEIF"
        }
    }

    private func isManual(_ control: ProControl) -> Bool {
        switch control {
        case .ev: return abs(camera.exposureBias) > 0.05
        case .iso, .shutter: return !camera.autoExposure
        case .whiteBalance: return !camera.autoWhiteBalance
        case .focus: return !camera.autoFocus
        }
    }

    static func shutterText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "–" }
        if seconds >= 0.4 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
}
