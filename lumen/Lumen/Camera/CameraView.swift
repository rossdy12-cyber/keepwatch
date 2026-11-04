import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A button in the zoom row: a lens, or a zoom on the main camera.
struct ZoomStop {
    let label: String
    let zoom: Double
    let lens: Lens?
}

struct CameraView: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var level = LevelMonitor()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("lumen.gridStyle") private var gridStyle: GridStyle = .thirds
    @AppStorage("lumen.histogram") private var showHistogram = true
    @AppStorage("lumen.level") private var showLevel = true
    @AppStorage("lumen.hardwareShutter") private var hardwareShutter = true
    @State private var timer = 0
    @State private var countdown: Int?
    @State private var control: ProControl?
    @State private var focusPoint: CGPoint?
    @State private var lockPoint: CGPoint?
    @State private var flashOverlay = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var editing: EditSource?
    @State private var showSettings = false
    @State private var shutterHeld = false

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
        .sheet(isPresented: $showSettings) {
            CameraSettingsSheet(camera: camera, hardwareShutter: $hardwareShutter)
        }
    }

    // MARK: Layout

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                CameraPreview(camera: camera, hardwareShutter: hardwareShutter && editing == nil && !showSettings) { point in
                    lockPoint = nil
                    focusPoint = point
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if focusPoint == point { focusPoint = nil }
                    }
                } onLock: { point in
                    focusPoint = nil
                    lockPoint = point
                } onHardwareButton: { phase in
                    switch phase {
                    case .began: shutterDown()
                    case .ended: shutterUp()
                    case .cancelled: if camera.isBursting { camera.stopBurst() }
                    }
                }
                OverlayImageView(feed: camera.overlay)
                if gridStyle != .off { GridOverlay(style: gridStyle) }
                if camera.mode == .photo && camera.aspect != .fourThree { AspectMask(aspect: camera.aspect) }
                if showLevel { LevelOverlay(level: level) }
                if let focusPoint {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(focusPoint)
                        .allowsHitTesting(false)
                }
                if camera.aeafLocked, let lockPoint {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 84, height: 84)
                        .position(lockPoint)
                        .allowsHitTesting(false)
                }
                viewfinderInfo
                if flashOverlay {
                    Color.black.opacity(0.8).allowsHitTesting(false)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            Spacer(minLength: 0)
            proControls
            lensPicker
            modePicker
            bottomBar
        }
    }

    /// Readouts, badges, progress and messages over the viewfinder.
    private var viewfinderInfo: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    readout
                    badges
                    if camera.mode.usesMovieFile { AudioMeterView(meter: camera.audioMeter) }
                }
                Spacer()
                if camera.isRecording, let started = camera.recordingStarted {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            if camera.mode == .timeLapse {
                                Text(String(format: "→ %.1fs", Double(camera.timeLapseFrames) / 30))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.red.opacity(0.35), in: Capsule())
                    }
                    Spacer()
                }
                if showHistogram { HistogramView(bins: camera.histogram) }
            }
            Spacer()
            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .shadow(radius: 8)
                Spacer()
            }
            if let progress = camera.stackProgress {
                VStack(spacing: 6) {
                    ProgressView(value: progress).tint(.yellow).frame(width: 160)
                    Text(camera.drive == .hdr ? "Merging…" : "Hold still…").font(.caption.weight(.semibold))
                }
                .padding(10)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
            if let message = camera.message {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .onTapGesture { camera.message = nil }
            }
            HStack(alignment: .bottom) {
                presetButtons
                Spacer()
                if abs(camera.effectiveZoom - camera.lensBase) > 0.05 || camera.zoom > 1.05 {
                    Text(String(format: "%.1f×", camera.effectiveZoom))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 34, height: 1).allowsHitTesting(false)
            }
        }
        .padding(10)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if camera.aeafLocked { badge("AE/AF LOCK", highlighted: true) }
            if camera.macroActive { badge("MACRO", highlighted: true) }
            if camera.mode == .photo && camera.drive != .single { badge(camera.drive.rawValue.uppercased(), highlighted: false) }
            if camera.isBursting { badge("\(camera.burstTaken)", highlighted: true) }
            if camera.intervalRunning {
                badge(camera.intervalShots > 0 ? "\(camera.intervalTaken)/\(camera.intervalShots)" : "\(camera.intervalTaken)", highlighted: true)
            }
            if camera.mode.isVideo && camera.auto180 { badge("180°", highlighted: false) }
            if camera.mode.isVideo && !camera.activeFormatLabel.isEmpty { badge(camera.activeFormatLabel, highlighted: false) }
            if camera.locationTagging { Image(systemName: "location.fill").font(.system(size: 9)) }
        }
        .allowsHitTesting(false)
    }

    private func badge(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(highlighted ? Color.yellow : Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(highlighted ? .black : .white)
    }

    private var presetButtons: some View {
        VStack(spacing: 6) {
            ForEach(1...3, id: \.self) { slot in
                Text("C\(slot)")
                    .font(.system(size: 11, weight: .heavy))
                    .frame(width: 34, height: 24)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(CameraPreset.load(slot) == nil ? 0.2 : 0.6), lineWidth: 1))
                    .onTapGesture { camera.recallPreset(slot) }
                    .onLongPressGesture(minimumDuration: 0.6) { camera.savePreset(slot) }
                    .accessibilityLabel("Custom setting \(slot)")
                    .accessibilityHint("Tap to load, long-press to save the current settings")
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            switch camera.mode {
            case .video:
                Menu {
                    ForEach(VideoQuality.allCases) { quality in
                        Button {
                            camera.setVideoQuality(quality)
                        } label: {
                            Label(quality.rawValue, systemImage: camera.videoQuality == quality ? "checkmark" : "")
                        }
                    }
                } label: {
                    boxed(camera.videoQuality.rawValue)
                }
                .disabled(camera.isRecording)
            case .slowMo:
                Menu {
                    Picker("Frame rate", selection: $camera.slowMoRate) {
                        ForEach(SlowMoRate.allCases) { Text("HD · \($0.label)").tag($0) }
                    }
                } label: {
                    boxed("HD · \(camera.slowMoRate.rawValue)")
                }
                .disabled(camera.isRecording)
            case .timeLapse:
                Menu {
                    Picker("A frame every", selection: $camera.timeLapseInterval) {
                        ForEach([0.25, 0.5, 1, 2, 5], id: \.self) { value in
                            Text(value < 1 ? String(format: "Every %.2g s", value) : "Every \(Int(value)) s").tag(value)
                        }
                    }
                } label: {
                    boxed(camera.timeLapseInterval < 1 ? String(format: "%.2gs", camera.timeLapseInterval) : "\(Int(camera.timeLapseInterval))s")
                }
                .disabled(camera.isRecording)
            case .photo:
                photoTopItems
            }
            assistMenu
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Camera settings")
        }
        .font(.system(size: 18))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var photoTopItems: some View {
        if camera.flashAvailable {
            Button { cycleFlash() } label: {
                Image(systemName: flashIcon)
                    .foregroundStyle(camera.flash == .off ? .white : .yellow)
            }
            .accessibilityLabel("Flash")
        }
        Menu {
            Section("Format") {
                ForEach(CaptureFormat.allCases) { format in
                    if (format != .raw && format != .rawPlusHEIF) || camera.rawAvailable {
                        Button {
                            camera.format = format
                        } label: {
                            Label(formatLabel(format), systemImage: camera.format == format ? "checkmark" : "")
                        }
                    }
                }
            }
            Section("Shape") {
                Picker("Shape", selection: $camera.aspect) {
                    ForEach(CaptureAspect.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        } label: {
            boxed((camera.format == .raw && camera.proRAW ? "ProRAW" : camera.format.rawValue)
                  + (camera.aspect == .fourThree ? "" : " · \(camera.aspect.rawValue)"))
        }
        Menu {
            Picker("Drive", selection: Binding(get: { camera.drive }, set: { camera.setDrive($0) })) {
                ForEach(DriveMode.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            Section { Text(camera.drive.help) }
        } label: {
            Image(systemName: camera.drive.icon)
                .foregroundStyle(camera.drive == .single ? .white : .yellow)
        }
        .disabled(camera.intervalRunning || camera.isBursting)
        .accessibilityLabel("Drive mode")
        Button { timer = timer == 0 ? 3 : (timer == 3 ? 10 : 0) } label: {
            HStack(spacing: 2) {
                Image(systemName: "timer")
                if timer > 0 { Text("\(timer)s").font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(timer > 0 ? .yellow : .white)
        }
        .accessibilityLabel("Self-timer")
        Menu {
            Picker("Look", selection: $camera.look) {
                ForEach(Look.all) { Text($0.name).tag($0.id) }
            }
            Section { Text("Shown live and added as an edit: Photos' Revert brings back the original.") }
        } label: {
            Image(systemName: "camera.filters")
                .foregroundStyle(camera.look == Look.none.id ? .white : .yellow)
        }
        .accessibilityLabel("Look")
    }

    private var assistMenu: some View {
        Menu {
            Picker("Grid", selection: $gridStyle) {
                ForEach(GridStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Level", isOn: $showLevel)
            Toggle("Histogram", isOn: $showHistogram)
            Section("Exposure and focus aids") {
                Toggle("Focus peaking", isOn: $camera.peaking)
                Toggle("Zebras", isOn: $camera.zebras)
                Toggle("False colour", isOn: $camera.falseColour)
            }
        } label: {
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(camera.peaking || camera.zebras || camera.falseColour ? .yellow : .white)
        }
        .accessibilityLabel("Viewfinder aids")
    }

    private func boxed(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white, lineWidth: 1))
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

    // MARK: Manual controls

    private var proControls: some View {
        VStack(spacing: 6) {
            if let control {
                controlSlider(control)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                if control == .focus && camera.manualFocusSupported {
                    focusPullRow.padding(.horizontal, 16)
                }
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

    /// Focus pull: mark two distances, then glide between them (for video).
    private var focusPullRow: some View {
        HStack(spacing: 10) {
            markButton("A", value: camera.focusA) { camera.setFocusMark(0) }
            markButton("B", value: camera.focusB) { camera.setFocusMark(1) }
            Button {
                camera.pullFocus()
            } label: {
                Label(camera.isPulling ? "Pulling…" : "Pull focus", systemImage: "arrow.left.and.right")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .disabled(camera.focusA == nil || camera.focusB == nil || camera.isPulling)
            Spacer()
            Text("\(Int(camera.focusPullSeconds))s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func markButton(_ name: String, value: Float?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(value.map { String(format: "%@ %.0f%%", name, $0 * 100) } ?? "Set \(name)")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(value == nil ? Color.white.opacity(0.15) : Color.yellow.opacity(0.85), in: Capsule())
                .foregroundStyle(value == nil ? .white : .black)
        }
    }

    @ViewBuilder
    private func controlSlider(_ control: ProControl) -> some View {
        switch control {
        case .zoom:
            sliderRow(title: String(format: "%.1f×", camera.effectiveZoom), isAuto: camera.zoom < 1.05,
                      autoAction: { camera.setZoom(1) }) {
                Slider(value: Binding(get: { log2(max(camera.effectiveZoom, 0.01)) },
                                      set: { camera.setEffectiveZoom(pow(2, $0)) }),
                       in: log2(camera.lensBase)...log2(camera.lensBase * Double(max(camera.maxZoom, 1.01))))
            }
        case .ev:
            sliderRow(title: String(format: "%+.1f EV", camera.exposureBias), isAuto: abs(camera.exposureBias) < 0.05,
                      autoAction: { camera.setExposureBias(0) }) {
                Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float(($0 * 3).rounded() / 3)) }),
                       in: Double(max(camera.minBias, -3))...Double(min(camera.maxBias, 3)))
            }
        case .iso:
            sliderRow(title: "ISO \(Int(camera.iso))", isAuto: camera.autoExposure, autoAction: { camera.setAutoExposure(true) }) {
                Slider(value: Binding(get: { log2(Double(max(camera.iso, 1))) }, set: { camera.setISO(Float(pow(2, $0))) }),
                       in: log2(Double(camera.minISO))...log2(Double(max(camera.maxISO, camera.minISO + 1))))
            }
        case .shutter:
            sliderRow(title: Self.shutterText(camera.shutter), isAuto: camera.autoExposure, autoAction: { camera.setAutoExposure(true) }) {
                Slider(value: Binding(get: { log2(max(camera.shutter, 1e-6)) }, set: { camera.setShutter(pow(2, $0)) }),
                       in: log2(camera.minShutter)...log2(max(camera.maxShutter, camera.minShutter * 2)))
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

    // MARK: Lenses and modes

    private var lensPicker: some View {
        HStack(spacing: 10) {
            if camera.drive == .portrait && camera.mode == .photo {
                Text("PORTRAIT · depth for background blur")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)
                    .frame(height: 40)
            } else {
                ForEach(zoomStops, id: \.label) { stop in
                    let active = !camera.macroActive && abs(camera.effectiveZoom - stop.zoom) < 0.15
                    Button {
                        if let lens = stop.lens {
                            if camera.currentLensID == lens.id && !camera.macroActive { camera.setZoom(1) } else { camera.selectLens(lens) }
                        } else {
                            camera.zoomPreset(stop.zoom)
                        }
                    } label: {
                        Text(active ? stop.label : stop.label.replacingOccurrences(of: "×", with: ""))
                            .font(.caption.weight(.bold))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(active ? 0.25 : 0.08), in: Circle())
                            .foregroundStyle(active ? .yellow : .white)
                    }
                    .disabled(camera.isRecording && stop.lens != nil)
                }
                if camera.macroAvailable {
                    Button { camera.setMacro(!camera.macroActive) } label: {
                        Image(systemName: "camera.macro")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(camera.macroActive ? 0.25 : 0.08), in: Circle())
                            .foregroundStyle(camera.macroActive ? .yellow : .white)
                    }
                    .accessibilityLabel(camera.macroActive ? "Macro off" : "Macro on")
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// Lens buttons, plus 2× on the main camera when there's no 2× lens (a crop of its high-resolution sensor).
    private var zoomStops: [ZoomStop] {
        var stops: [ZoomStop] = camera.lenses
            .filter { $0.position == .back }
            .map { ZoomStop(label: $0.label, zoom: $0.label == "0.5×" ? 0.5 : ($0.label == "1×" ? 1 : $0.order.rounded()), lens: $0) }
        if camera.lenses.contains(where: { $0.label == "1×" }) && !stops.contains(where: { abs($0.zoom - 2) < 0.3 }) {
            stops.append(ZoomStop(label: "2×", zoom: 2, lens: nil))
        }
        return stops.sorted { $0.zoom < $1.zoom }
    }

    private var modePicker: some View {
        HStack(spacing: 20) {
            ForEach(CaptureMode.allCases) { item in
                Button { camera.setMode(item) } label: {
                    Text(item.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(camera.mode == item ? .yellow : .white.opacity(0.7))
                }
                .disabled(camera.isRecording || camera.intervalRunning || camera.isBursting)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Shutter row

    private var bottomBar: some View {
        HStack {
            Button {
                if camera.lastWasVideo, let url = camera.lastVideoURL {
                    editing = EditSource(videoURL: url)
                } else if let id = camera.lastAssetID {
                    editing = EditSource(assetID: id)
                }
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

            shutterButton

            HStack(spacing: 18) {
                PhotosPicker(selection: $libraryItem, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                    Image(systemName: "photo.on.rectangle")
                }
                .accessibilityLabel("Edit a photo or video from your library")
                Button { flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                }
                .disabled(camera.isRecording)
                .accessibilityLabel("Switch camera")
            }
            .font(.title3)
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 18)
        .padding(.top, 4)
    }

    private var shutterBusy: Bool {
        (camera.mode == .photo && camera.isCapturing && !camera.intervalRunning && !camera.isBursting) || countdown != nil
    }

    private var shutterButton: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
            if camera.mode.isVideo {
                RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 31)
                    .fill(Color.red)
                    .frame(width: camera.isRecording ? 30 : 62, height: camera.isRecording ? 30 : 62)
                    .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
            } else if camera.intervalRunning {
                RoundedRectangle(cornerRadius: 6).fill(Color.yellow).frame(width: 30, height: 30)
            } else {
                Circle()
                    .fill(shutterBusy ? Color.gray : (camera.isBursting ? Color.yellow : Color.white))
                    .frame(width: camera.isBursting || shutterHeld ? 54 : 62, height: camera.isBursting || shutterHeld ? 54 : 62)
                Image(systemName: camera.drive.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black.opacity(camera.drive == .single ? 0 : 0.6))
            }
        }
        .frame(width: 80, height: 80)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !shutterHeld {
                        shutterHeld = true
                        shutterDown()
                    }
                }
                .onEnded { _ in
                    shutterHeld = false
                    shutterUp()
                }
        )
        .opacity(shutterBusy ? 0.6 : 1)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(shutterLabel)
        .accessibilityAction { shutterPressed() }
    }

    private var shutterLabel: String {
        if camera.mode.isVideo { return camera.isRecording ? "Stop recording" : "Record" }
        if camera.intervalRunning { return "Stop interval shooting" }
        return "Take photo"
    }

    // MARK: Actions

    /// Shutter (or volume button / Camera Control) pressed down: in Burst, holding starts continuous shooting.
    private func shutterDown() {
        guard camera.mode == .photo, camera.drive == .burst, !shutterBusy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if (shutterHeld || hardwareHeld) && !camera.isBursting { camera.startBurst() }
        }
        hardwareHeld = true
    }

    @State private var hardwareHeld = false

    private func shutterUp() {
        hardwareHeld = false
        if camera.isBursting {
            camera.stopBurst()
            return
        }
        shutterPressed()
    }

    private func shutterPressed() {
        if camera.mode.isVideo {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            camera.toggleRecording()
        } else if camera.intervalRunning || camera.drive == .interval {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if camera.intervalRunning { camera.toggleInterval() } else { shoot() }
        } else if !shutterBusy {
            shoot()
        }
    }

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
        if camera.drive != .interval {
            flashOverlay = true
            withAnimation(.easeOut(duration: 0.25)) { flashOverlay = false }
        }
        camera.capture()
    }

    private func flipCamera() {
        if camera.drive == .portrait && camera.mode == .photo {
            // Portrait swaps between the back depth camera and the front TrueDepth camera.
            camera.setDrive(.single)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                flipToOtherSide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { camera.setDrive(.portrait) }
            }
            return
        }
        flipToOtherSide()
    }

    private func flipToOtherSide() {
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
        case .zoom: return camera.zoom > 1.05
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
