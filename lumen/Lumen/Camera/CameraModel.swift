import AVFoundation
import CoreLocation
import Photos
import UIKit

/// What a photo is saved as.
enum CaptureFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF"
    case jpeg = "JPEG"
    case raw = "RAW"
    case rawPlusHEIF = "RAW+"
    var id: String { rawValue }
}

/// One of the iPhone's cameras.
struct Lens: Identifiable, Equatable {
    let id: String          // AVCaptureDevice.uniqueID
    let label: String       // "0.5×", "1×", "3×", "Front"
    let position: AVCaptureDevice.Position
    let order: Double
}

/// Which manual control the slider is adjusting.
enum ProControl: String, CaseIterable, Identifiable {
    case zoom = "Z", ev = "EV", iso = "ISO", shutter = "S", whiteBalance = "WB", focus = "F"
    var id: String { rawValue }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "PHOTO", video = "VIDEO", slowMo = "SLO-MO", timeLapse = "TIME-LAPSE", spatial = "SPATIAL"
    var id: String { rawValue }
    var isVideo: Bool { self != .photo }
    /// Recorded straight to a movie file (time-lapse writes its own).
    var usesMovieFile: Bool { self == .video || self == .slowMo || self == .spatial }
}

/// Video resolution and frame rate.
enum VideoQuality: String, CaseIterable, Identifiable {
    case uhd24 = "4K · 24", uhd30 = "4K · 30", uhd60 = "4K · 60", hd30 = "HD · 30", hd60 = "HD · 60"
    var id: String { rawValue }
    var width: Int32 { self == .hd30 || self == .hd60 ? 1920 : 3840 }
    var height: Int32 { self == .hd30 || self == .hd60 ? 1080 : 2160 }
    var fps: Double {
        switch self {
        case .uhd24: return 24
        case .uhd30, .hd30: return 30
        case .uhd60, .hd60: return 60
        }
    }
}

/// A resolution and frame rate to look for among a camera's formats.
struct VideoTarget: Equatable {
    let width: Int32
    let height: Int32
    let fps: Double
    var label: String { "\(width >= 3840 ? "4K" : (width >= 1920 ? "HD" : "720p")) · \(Int(fps))" }
}

/// The camera: lenses, manual controls, capture and saving.
/// Session work runs on its own queue; anything the screen shows is published on the main thread.
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "lumen.camera.session")
    let videoQueue = DispatchQueue(label: "lumen.camera.frames")
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let movieOutput = AVCaptureMovieFileOutput()
    var audioInput: AVCaptureDeviceInput?

    // Session-queue state.
    /// The mode the session is set up for.
    var sessionMode: CaptureMode = .photo
    /// The mode the current recording was started in.
    var recordingMode: CaptureMode = .video
    /// Portrait drive: a depth-capable (virtual) camera is in use.
    var portraitSession = false
    var macroSession = false
    var device: AVCaptureDevice?
    var input: AVCaptureDeviceInput?
    var processors: [Int64: AnyObject] = [:]
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationObservation: NSKeyValueObservation?
    var controlsHelper: AnyObject?
    var burstTimer: DispatchSourceTimer?
    var burstInFlight = 0
    var auto180Timer: DispatchSourceTimer?
    /// Spatial video: the dual (wide + ultra-wide) camera is in use.
    var spatialSession = false
    /// Live Photos are switched on in the photo output.
    var liveSession = false
    var readiness: AVCapturePhotoOutputReadinessCoordinator?
    private var configured = false

    // Frame-queue state.
    var lastHistogram = Date.distantPast
    var lastOverlay = Date.distantPast
    var overlayShown = false
    var assist = AssistSettings()
    let frameAssist = FrameAssist()
    var stacker: FrameStacker?
    var lastDetection = Date.distantPast
    var lastLoupe = Date.distantPast
    var scanQuad: [CGPoint]?
    var scanRequested = false
    var timeLapse: TimeLapseWriter?

    // Main-thread helpers.
    let overlay = OverlayFeed()
    let detection = DetectionFeed()
    let audioMeter = AudioMeter()
    let location = LocationProvider()
    var intervalTimer: Timer?
    var meterTimer: Timer?
    var pullTimer: Timer?
    var macroCloseTicks = 0
    var macroFarTicks = 0
    var macroWasAutomatic = false

    // What the screen shows.
    @Published var authorised = true
    @Published var lenses: [Lens] = []
    @Published var currentLensID: String?
    @Published var format: CaptureFormat = CaptureFormat(rawValue: Prefs.string("format", "HEIF")) ?? .heif {
        didSet { Prefs.set("format", format.rawValue) }
    }
    /// Full-sensor (48 MP) vs binned (12 MP) photos.
    @Published var resolution: PhotoResolution = PhotoResolution(rawValue: Prefs.string("resolution", "Max")) ?? .max
    var sessionWantsMaxResolution = true
    @Published var maxResolutionAvailable = false
    /// The biggest resolution this camera can shoot, as "48 MP".
    @Published var maxResolutionLabel = ""
    @Published var mirrorFront = Prefs.bool("mirrorFront", false) { didSet { Prefs.set("mirrorFront", mirrorFront) } }
    @Published var proRAW = false
    @Published var rawAvailable = false
    @Published var flash: AVCaptureDevice.FlashMode = .off
    @Published var flashAvailable = false

    @Published var autoExposure = true
    @Published var iso: Float = 100
    @Published var minISO: Float = 25
    @Published var maxISO: Float = 3200
    @Published var shutter: Double = 1.0 / 60
    @Published var minShutter: Double = 1.0 / 8000
    @Published var maxShutter: Double = 1.0
    @Published var exposureBias: Float = 0
    @Published var minBias: Float = -4
    @Published var maxBias: Float = 4
    /// Focus and exposure held where you long-pressed.
    @Published var aeafLocked = false

    @Published var autoWhiteBalance = true
    @Published var temperature: Float = 5500
    @Published var tint: Float = 0

    @Published var autoFocus = true
    @Published var lensPosition: Float = 0.5
    @Published var manualFocusSupported = true

    @Published var zoom: CGFloat = 1
    @Published var maxZoom: CGFloat = 10
    /// How zoomed-in the current lens is compared with the main one (0.5 for ultra wide, 1, 3, 5…).
    @Published var lensBase: Double = 1
    @Published var macroActive = false
    @Published var autoMacro = Prefs.bool("autoMacro", true) { didSet { Prefs.set("autoMacro", autoMacro) } }

    @Published var mode: CaptureMode = .photo
    @Published var videoQuality: VideoQuality = .uhd30
    @Published var slowMoRate: SlowMoRate = SlowMoRate(rawValue: Prefs.int("slowMoRate", 240)) ?? .fps240 {
        didSet { Prefs.set("slowMoRate", slowMoRate.rawValue); if mode == .slowMo { sessionQueue.async { self.applyVideoFormat(announce: true) } } }
    }
    @Published var timeLapseInterval = Prefs.double("timeLapseInterval", 0.5) { didSet { Prefs.set("timeLapseInterval", timeLapseInterval) } }
    @Published var timeLapseFrames = 0
    @Published var isRecording = false
    @Published var recordingStarted: Date?
    @Published var lastVideoURL: URL?
    @Published var lastWasVideo = false
    @Published var activeFormatLabel = ""
    @Published var auto180 = false
    @Published var program: ExposureProgram = .auto
    @Published var aeLocked = false
    @Published var awbLocked = false
    @Published var hdrVideo = Prefs.bool("hdrVideo", false) { didSet { Prefs.set("hdrVideo", hdrVideo); refreshVideoFormat() } }
    @Published var hdrVideoAvailable = false
    @Published var spatialAvailable = false
    @Published var stabilization = StabilizationChoice(rawValue: Prefs.string("stabilization", "Auto")) ?? .auto {
        didSet { Prefs.set("stabilization", stabilization.rawValue); refreshVideoFormat() }
    }
    @Published var slowMoEditable = Prefs.bool("slowMoEditable", true) { didSet { Prefs.set("slowMoEditable", slowMoEditable) } }
    @Published var frameGuide = FrameGuide(rawValue: Prefs.string("frameGuide", "None")) ?? .none {
        didSet { Prefs.set("frameGuide", frameGuide.rawValue) }
    }
    /// Anamorphic lens adapter: how much to stretch the preview back out (1 = none).
    @Published var anamorphic = Prefs.double("anamorphic", 1) { didSet { Prefs.set("anamorphic", anamorphic) } }
    @Published var logAvailable = false
    @Published var proResAvailable = false
    @Published var useLog = Prefs.bool("useLog", false) { didSet { Prefs.set("useLog", useLog); refreshVideoFormat() } }
    @Published var useProRes = Prefs.bool("useProRes", false) { didSet { Prefs.set("useProRes", useProRes); refreshVideoFormat() } }
    @Published var micOptions: [MicOption] = []
    @Published var micID: String?
    @Published var focusA: Float?
    @Published var focusB: Float?
    @Published var isPulling = false
    @Published var focusPullSeconds = Prefs.double("focusPull", 2) { didSet { Prefs.set("focusPull", focusPullSeconds) } }

    @Published var drive: DriveMode = DriveMode(rawValue: Prefs.string("drive", "Single")) ?? .single
    @Published var aspect: CaptureAspect = CaptureAspect(rawValue: Prefs.string("aspect", "4:3")) ?? .fourThree {
        didSet { Prefs.set("aspect", aspect.rawValue) }
    }
    @Published var look = Prefs.string("look", Look.none.id) { didSet { Prefs.set("look", look); updateAssist() } }
    @Published var peaking = false { didSet { updateAssist() } }
    @Published var zebras = false { didSet { updateAssist() } }
    @Published var zebraLevel = Prefs.double("zebraLevel", 0.95) { didSet { Prefs.set("zebraLevel", zebraLevel); updateAssist() } }
    @Published var falseColour = false { didSet { updateAssist() } }
    @Published var longExposureStyle = LongExposureStyle(rawValue: Prefs.string("longStyle", "Silky water")) ?? .silky {
        didSet { Prefs.set("longStyle", longExposureStyle.rawValue) }
    }
    @Published var longExposureSeconds = Prefs.double("longSeconds", 2) { didSet { Prefs.set("longSeconds", longExposureSeconds) } }
    @Published var onTripod = Prefs.bool("tripod", false) { didSet { Prefs.set("tripod", onTripod) } }
    @Published var keepBracketFrames = Prefs.bool("keepBrackets", false) { didSet { Prefs.set("keepBrackets", keepBracketFrames) } }
    @Published var intervalSeconds = Prefs.double("intervalSeconds", 5) { didSet { Prefs.set("intervalSeconds", intervalSeconds) } }
    @Published var intervalShots = Prefs.int("intervalShots", 0) { didSet { Prefs.set("intervalShots", intervalShots) } }
    @Published var intervalRunning = false
    @Published var intervalTaken = 0
    @Published var isBursting = false
    @Published var burstTaken = 0
    /// 0–1 while a night, long-exposure or HDR shot is being made.
    @Published var stackProgress: Double?
    @Published var locationTagging = Prefs.bool("location", false) {
        didSet {
            Prefs.set("location", locationTagging)
            if locationTagging { location.start() } else { location.stop() }
        }
    }

    @Published var histogram: [Float] = Array(repeating: 0, count: 64)
    @Published var rgbHistogram: [[Float]] = []
    @Published var waveform: CGImage?
    @Published var scopeStyle = ScopeStyle(rawValue: Prefs.string("scope", "Brightness")) ?? .luma {
        didSet { Prefs.set("scope", scopeStyle.rawValue); updateAssist() }
    }
    @Published var livePhoto = Prefs.bool("live", false) { didSet { Prefs.set("live", livePhoto); applyLivePhoto() } }
    /// False while the camera is busy and another photo would have to wait.
    @Published var shutterReady = true
    @Published var saveToAlbum = Prefs.bool("album", true) { didSet { Prefs.set("album", saveToAlbum) } }
    @Published var nasBackup = Prefs.bool("nasBackup", false) {
        didSet { Prefs.set("nasBackup", nasBackup); if nasBackup { NASBackup.shared.kick() } }
    }
    @Published var detectCodes = Prefs.bool("detect", true) {
        didSet {
            Prefs.set("detect", detectCodes)
            updateAssist()
            if !detectCodes { detection.code = nil; detection.document = nil }
        }
    }
    /// Magnified centre while focusing by hand.
    @Published var loupe = false { didSet { updateAssist() } }
    @Published var lastThumbnail: UIImage?
    @Published var lastAssetID: String?
    /// The last photo's data, kept so it still opens from the thumbnail when it wasn't saved to Photos (Immich-only).
    @Published var lastPhotoData: Data?
    @Published var isCapturing = false
    @Published var message: String?

    // MARK: Starting and stopping

    func start() {
        if locationTagging { location.start() }
        sessionWantsMaxResolution = resolution == .max
        updateAssist()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.authorised = granted }
                if granted { self.configureAndRun() }
            }
        default:
            DispatchQueue.main.async { self.authorised = false }
        }
    }

    func stop() {
        if isRecording { toggleRecording() }
        if intervalRunning { toggleInterval() }
        if isBursting { stopBurst() }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// The preview layer, so photos come out the right way up (whichever way the phone is held).
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        sessionQueue.async { self.makeRotationCoordinator() }
    }

    private func configureAndRun() {
        sessionQueue.async {
            if !self.configured {
                self.configure()
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        let found = Self.discoverLenses()
        DispatchQueue.main.async { self.lenses = found }
        guard let first = found.first(where: { $0.label == "1×" }) ?? found.first,
              let camera = AVCaptureDevice(uniqueID: first.id) else {
            publishMessage("No camera found.")
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        coordinator.delegate = self
        readiness = coordinator
        configured = true
        use(camera)
        let spatial = Self.spatialCamera() != nil
        DispatchQueue.main.async { self.spatialAvailable = spatial }
    }

    /// The camera pair that records spatial video (iPhone 15 Pro, 16 and later), if this iPhone has one.
    static func spatialCamera() -> AVCaptureDevice? {
        guard #available(iOS 18.0, *),
              let dual = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back),
              dual.formats.contains(where: { supportsSpatial($0) }) else { return nil }
        return dual
    }

    static func supportsSpatial(_ format: AVCaptureDevice.Format) -> Bool {
        if #available(iOS 18.0, *) { return format.isSpatialVideoCaptureSupported }
        return false
    }

    /// Every physical camera (manual controls only work on the physical ones, not the combined "virtual" camera).
    static func discoverLenses() -> [Lens] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified)
        let wide = discovery.devices.first { $0.deviceType == .builtInWideAngleCamera && $0.position == .back }
        let wideFOV = wide.map { Double($0.activeFormat.videoFieldOfView) } ?? 70
        var lenses: [Lens] = []
        for device in discovery.devices {
            if device.position == .front {
                if device.deviceType == .builtInWideAngleCamera {
                    lenses.append(Lens(id: device.uniqueID, label: "Front", position: .front, order: 100))
                }
                continue
            }
            // How much closer this lens is than the main one, from the field of view.
            let fov = Double(device.activeFormat.videoFieldOfView)
            let factor = tan(wideFOV / 2 * .pi / 180) / tan(fov / 2 * .pi / 180)
            let label: String
            switch device.deviceType {
            case .builtInUltraWideCamera: label = "0.5×"
            case .builtInWideAngleCamera: label = "1×"
            default: label = String(format: "%.0f×", factor.rounded())
            }
            lenses.append(Lens(id: device.uniqueID, label: label, position: .back, order: factor))
        }
        return lenses.sorted { $0.order < $1.order }
    }

    /// Picks a lens (from the lens buttons): leaves macro and portrait cameras behind.
    func selectLens(_ lens: Lens) {
        sessionQueue.async {
            self.macroSession = false
            guard lens.id != self.device?.uniqueID, let camera = AVCaptureDevice(uniqueID: lens.id) else {
                DispatchQueue.main.async { self.macroActive = false }
                return
            }
            self.use(camera)
        }
    }

    /// Switches to a camera, starting at a zoom factor. Call on the session queue.
    func use(_ camera: AVCaptureDevice, zoom startZoom: CGFloat? = nil) {
        guard let newInput = try? AVCaptureDeviceInput(device: camera) else {
            publishMessage("Couldn't open that camera.")
            return
        }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
            device = camera
        } else if let input {
            session.addInput(input)
        }
        let active = device ?? camera
        // Photo resolution: the full sensor (48 MP on the main camera), or binned ~12 MP. Depth tops out at 12 MP.
        let sizes = active.activeFormat.supportedMaxPhotoDimensions
        let pool = portraitSession ? sizes.filter { $0.width <= 4032 } : sizes
        let usable = pool.isEmpty ? sizes : pool
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let biggest = usable.max(by: { area($0) < area($1) })
        let chosen: CMVideoDimensions?
        if sessionWantsMaxResolution {
            chosen = biggest
        } else {
            chosen = usable.filter { area($0) <= 12_500_000 }.max(by: { area($0) < area($1) })
                ?? usable.min(by: { area($0) < area($1) })
        }
        if let chosen { photoOutput.maxPhotoDimensions = chosen }
        let hasMax = (biggest.map(area) ?? 0) > 13_000_000
        let maxLabel = biggest.map { "\(Int((Double(area($0)) / 1_000_000).rounded())) MP" } ?? ""
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = !portraitSession }
        let depth = portraitSession && photoOutput.isDepthDataDeliverySupported
        if !depth, photoOutput.isPortraitEffectsMatteDeliveryEnabled { photoOutput.isPortraitEffectsMatteDeliveryEnabled = false }
        if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = depth }
        if depth, photoOutput.isPortraitEffectsMatteDeliverySupported { photoOutput.isPortraitEffectsMatteDeliveryEnabled = true }
        configurePhotoFeatures()
        installSystemControls(for: active)
        session.commitConfiguration()
        makeRotationCoordinator()
        if sessionMode.isVideo { applyVideoFormat(announce: false) }

        // A virtual camera starts on its widest lens: begin where the main lens takes over (1×).
        var base = lenses(matching: active.uniqueID)
        var initialZoom = startZoom ?? 1
        if active.isVirtualDevice, active.position == .back, let switchOver = active.virtualDeviceSwitchOverVideoZoomFactors.first {
            let factor = CGFloat(truncating: switchOver)
            base = 1 / Double(factor)
            if startZoom == nil { initialZoom = factor }
        }
        initialZoom = max(active.minAvailableVideoZoomFactor, min(active.maxAvailableVideoZoomFactor, initialZoom))
        if (try? active.lockForConfiguration()) != nil {
            active.videoZoomFactor = initialZoom
            active.unlockForConfiguration()
        }

        let rawFormats = photoOutput.availableRawPhotoPixelFormatTypes
        let proRAW = rawFormats.contains { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let anyRAW = !rawFormats.isEmpty && !portraitSession
        let macro = macroSession && active.deviceType == .builtInUltraWideCamera
        let snapshot = (
            id: active.uniqueID,
            minISO: active.activeFormat.minISO, maxISO: active.activeFormat.maxISO,
            minShutter: max(active.activeFormat.minExposureDuration.seconds, 1.0 / 16000),
            maxShutter: min(active.activeFormat.maxExposureDuration.seconds, 1.0),
            minBias: active.minExposureTargetBias, maxBias: active.maxExposureTargetBias,
            maxZoom: min(active.maxAvailableVideoZoomFactor, 15),
            flash: active.hasFlash, manualFocus: active.isLockingFocusWithCustomLensPositionSupported,
            log: active.formats.contains { $0.supportedColorSpaces.contains(.appleLog) },
            hdr: active.formats.contains { $0.supportedColorSpaces.contains(.HLG_BT2020) }
        )
        DispatchQueue.main.async {
            self.currentLensID = snapshot.id
            self.minISO = snapshot.minISO
            self.maxISO = snapshot.maxISO
            self.minShutter = snapshot.minShutter
            self.maxShutter = snapshot.maxShutter
            self.minBias = snapshot.minBias
            self.maxBias = snapshot.maxBias
            self.maxZoom = snapshot.maxZoom
            self.flashAvailable = snapshot.flash
            self.manualFocusSupported = snapshot.manualFocus
            self.logAvailable = snapshot.log
            self.hdrVideoAvailable = snapshot.hdr
            self.aeLocked = false
            self.awbLocked = false
            if self.program == .shutter || self.program == .iso { self.program = .auto }
            self.proRAW = proRAW
            self.rawAvailable = anyRAW
            if !anyRAW && (self.format == .raw || self.format == .rawPlusHEIF) && !self.portraitDriveActive { self.format = .heif }
            self.zoom = initialZoom
            self.lensBase = base
            self.macroActive = macro
            self.maxResolutionAvailable = hasMax
            self.maxResolutionLabel = maxLabel
            // A new camera starts in auto; manual values are per-camera.
            self.autoExposure = true
            self.autoWhiteBalance = true
            self.autoFocus = true
            self.aeafLocked = false
            self.exposureBias = 0
            self.focusA = nil
            self.focusB = nil
            if self.auto180 { self.startAuto180() }
        }
    }

    /// Instant shutter, overlapping captures, Live Photos. Call on the session queue, inside a configuration.
    func configurePhotoFeatures() {
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
            if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
        }
        // Deferred delivery hands back a "proxy" that Photos finalises later. When we're uploading to
        // Immich we never hand it to Photos, so turn it off and take the finished HEIC straight away.
        let immichActive = PhotoSaver.saveTarget.wantsImmich && ImmichBackup.shared.isConfigured
        if photoOutput.isAutoDeferredPhotoDeliverySupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = !portraitSession && !immichActive
        }
        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = liveSession && sessionMode == .photo
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoAutoTrimmingEnabled = true }
        }
    }

    /// Live Photos on or off (with the microphone for their sound).
    func applyLivePhoto() {
        let on = livePhoto
        sessionQueue.async {
            self.liveSession = on
            guard self.sessionMode == .photo else { return }
            self.session.beginConfiguration()
            self.updatePhotoAudio()
            self.configurePhotoFeatures()
            self.session.commitConfiguration()
            if on && !self.photoOutput.isLivePhotoCaptureEnabled {
                self.publishMessage("Live Photos aren't available with this camera or drive.")
            }
        }
    }

    /// Photo mode keeps the microphone only for Live Photos. Call on the session queue, inside a configuration.
    func updatePhotoAudio() {
        if liveSession {
            if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioInput = micInput
            }
        } else if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
    }

    private var portraitDriveActive: Bool { drive == .portrait }

    /// The zoom of a lens relative to the main camera, from the discovered list.
    private func lenses(matching id: String) -> Double {
        let found = Self.discoverLenses().first { $0.id == id }
        guard let found else { return 1 }
        return found.position == .front ? 1 : found.order
    }

    func makeRotationCoordinator() {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        alignFrameOutput(angle: coordinator.videoRotationAngleForHorizonLevelPreview)
        // The screen stays portrait; the preview always shows the scene upright.
        DispatchQueue.main.async {
            self.previewLayer?.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            self.rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.previewLayer?.connection?.videoRotationAngle = angle }
                self?.sessionQueue.async { self?.alignFrameOutput(angle: angle) }
            }
        }
    }

    /// Live frames (for overlays, stacking and time-lapse) come the same way up as the preview. Call on the session queue.
    func alignFrameOutput(angle: CGFloat? = nil) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let angle = angle ?? rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device?.position == .front
        }
    }

    /// How much further the saved photo must turn than the live frames (degrees clockwise).
    func captureRotationFromFrames() -> CGFloat {
        guard let coordinator = rotationCoordinator else { return 0 }
        return coordinator.videoRotationAngleForHorizonLevelCapture - coordinator.videoRotationAngleForHorizonLevelPreview
    }

    // MARK: Manual controls

    func configureDevice(_ change: @escaping (AVCaptureDevice) throws -> Void) {
        sessionQueue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                try change(device)
                device.unlockForConfiguration()
            } catch {
                self.publishMessage("The camera didn't accept that setting.")
            }
        }
    }

    func setAutoExposure(_ on: Bool) {
        autoExposure = on
        aeafLocked = false
        aeLocked = false
        if on {
            program = .auto
            stopPriority()
            configureDevice { device in
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
        } else {
            program = .manual
            applyManualExposure()
        }
    }

    func setExposureBias(_ bias: Float) {
        exposureBias = bias
        configureDevice { device in
            device.setExposureTargetBias(max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias)), completionHandler: nil)
        }
    }

    func setISO(_ value: Float) {
        iso = value
        autoExposure = false
        aeLocked = false
        if program == .iso {
            startPriority()
            return
        }
        program = .manual
        stopPriority()
        applyManualExposure()
    }

    func setShutter(_ seconds: Double) {
        shutter = seconds
        autoExposure = false
        aeLocked = false
        if program == .shutter && !auto180 {
            startPriority()
            return
        }
        program = .manual
        stopPriority()
        applyManualExposure()
    }

    /// A for auto, S for shutter priority, ISO for ISO priority, M for manual.
    func setProgram(_ newProgram: ExposureProgram) {
        if newProgram != .shutter { auto180 = false }
        switch newProgram {
        case .auto:
            setAutoExposure(true)
        case .manual:
            program = .manual
            autoExposure = false
            stopPriority()
            applyManualExposure()
        case .shutter, .iso:
            program = newProgram
            autoExposure = false
            aeLocked = false
            startPriority()
        }
    }

    /// AE-L: hold the exposure the camera has chosen.
    func toggleAELock() {
        let lock = !aeLocked
        aeLocked = lock
        if lock && program != .auto { setAutoExposure(true); aeLocked = true }
        configureDevice { device in
            if lock, device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// AWB-L: hold the white balance the camera has chosen.
    func toggleAWBLock() {
        let lock = !awbLocked
        awbLocked = lock
        autoWhiteBalance = true
        configureDevice { device in
            if lock, device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    /// Grey card: fill the frame with something white or grey, then set white balance from it.
    func whiteBalanceFromGreyCard() {
        awbLocked = false
        autoWhiteBalance = false
        configureDevice { device in
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var gains = device.grayWorldDeviceWhiteBalanceGains
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = max(1, min(maxGain, gains.redGain))
            gains.greenGain = max(1, min(maxGain, gains.greenGain))
            gains.blueGain = max(1, min(maxGain, gains.blueGain))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            let values = device.temperatureAndTintValues(for: gains)
            DispatchQueue.main.async {
                self.temperature = values.temperature
                self.tint = values.tint
                self.message = "White balance set from the grey card."
            }
        }
    }

    func applyManualExposure() {
        let iso = self.iso, shutter = self.shutter
        configureDevice { device in
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            let seconds = max(format.minExposureDuration.seconds, min(format.maxExposureDuration.seconds, shutter))
            let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            device.setExposureModeCustom(duration: duration, iso: max(format.minISO, min(format.maxISO, iso)), completionHandler: nil)
        }
    }

    func setAutoWhiteBalance(_ on: Bool) {
        autoWhiteBalance = on
        awbLocked = false
        if on {
            configureDevice { device in
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
        } else {
            applyWhiteBalance()
        }
    }

    func setWhiteBalance(temperature: Float, tint: Float) {
        self.temperature = temperature
        self.tint = tint
        autoWhiteBalance = false
        applyWhiteBalance()
    }

    private func applyWhiteBalance() {
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
        configureDevice { device in
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = max(1, min(maxGain, gains.redGain))
            gains.greenGain = max(1, min(maxGain, gains.greenGain))
            gains.blueGain = max(1, min(maxGain, gains.blueGain))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    func setAutoFocus(_ on: Bool) {
        autoFocus = on
        aeafLocked = false
        if on {
            configureDevice { device in
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
        } else {
            setLensPosition(lensPosition)
        }
    }

    func setLensPosition(_ position: Float) {
        lensPosition = position
        autoFocus = false
        configureDevice { device in
            guard device.isLockingFocusWithCustomLensPositionSupported else { return }
            device.setFocusModeLocked(lensPosition: max(0, min(1, position)), completionHandler: nil)
        }
    }

    /// Tap to focus and expose at a point (0–1 device coordinates). Also releases an AE/AF lock.
    func focus(at point: CGPoint) {
        let keepManualExposure = program != .auto
        DispatchQueue.main.async {
            self.autoFocus = true
            self.aeafLocked = false
            if !keepManualExposure { self.aeLocked = false }
            if !self.autoExposure && !keepManualExposure { self.autoExposure = true }
        }
        configureDevice { device in
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
            }
            if device.isExposurePointOfInterestSupported, !keepManualExposure {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    /// Long press: focus and expose on a point once, then hold both until the next tap.
    func lockFocusAndExposure(at point: CGPoint) {
        auto180 = false
        program = .auto
        aeLocked = false
        stopPriority()
        autoFocus = true
        autoExposure = true
        aeafLocked = true
        configureDevice { device in
            device.isSubjectAreaChangeMonitoringEnabled = false
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus   // focuses once, then stays
            } else if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose   // meters once, then stays
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        }
    }

    /// Zoom as people think of it (0.5×, 1×, 2×…), whichever lens is in use.
    var effectiveZoom: Double { lensBase * Double(zoom) }

    func setEffectiveZoom(_ value: Double) {
        setZoom(CGFloat(value / max(lensBase, 0.01)))
    }

    /// 2× on the main camera: a crop of its high-resolution sensor (what Apple's Camera does on iPhones without a 2× lens).
    func zoomPreset(_ effective: Double) {
        if let main = lenses.first(where: { $0.label == "1×" }), currentLensID != main.id {
            sessionQueue.async {
                self.macroSession = false
                guard let camera = AVCaptureDevice(uniqueID: main.id) else { return }
                self.use(camera, zoom: CGFloat(effective))
            }
        } else {
            setEffectiveZoom(effective)
        }
    }

    func setZoom(_ factor: CGFloat) {
        let clamped = max(1, min(maxZoom, factor))
        zoom = clamped
        configureDevice { device in
            device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(device.maxAvailableVideoZoomFactor, clamped))
        }
    }

    // MARK: Modes

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording, !intervalRunning, !isBursting else { return }
        let oldMode = mode
        mode = newMode
        if oldMode.isVideo && !newMode.isVideo && auto180 { setAuto180(false) }
        if newMode.isVideo, drive == .portrait { setDrive(.single) }
        updateAssist()
        if newMode.usesMovieFile && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.applyMode(newMode) }
            }
        } else {
            sessionQueue.async { self.applyMode(newMode) }
        }
        if newMode.usesMovieFile { startMeters() } else { stopMeters() }
    }

    func setVideoQuality(_ quality: VideoQuality) {
        videoQuality = quality
        sessionQueue.async { self.applyVideoFormat(announce: true) }
    }

    /// Full-sensor (48 MP) or binned (12 MP) photos. Re-picks the camera's photo size.
    func setResolution(_ newResolution: PhotoResolution) {
        resolution = newResolution
        Prefs.set("resolution", newResolution.rawValue)
        let wantsMax = newResolution == .max
        sessionQueue.async {
            self.sessionWantsMaxResolution = wantsMax
            if let device = self.device, self.sessionMode == .photo { self.use(device) }
        }
    }

    private func refreshVideoFormat() {
        guard mode.isVideo, mode != .timeLapse else { return }
        sessionQueue.async { self.applyVideoFormat(announce: true) }
    }

    /// Call on the session queue.
    private func applyMode(_ newMode: CaptureMode) {
        let leavingSpatial = sessionMode == .spatial && newMode != .spatial
        sessionMode = newMode
        session.beginConfiguration()
        if newMode.isVideo {
            // The movie recorder goes in first: some iPhones can't also feed live frames while recording.
            if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoCaptureEnabled = false }
            if newMode.usesMovieFile {
                if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
                if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                   let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
                   session.canAddInput(micInput) {
                    session.addInput(micInput)
                    audioInput = micInput
                }
            } else {
                if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
                if let audioInput { session.removeInput(audioInput) }
                audioInput = nil
            }
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.commitConfiguration()
            alignFrameOutput()
            if newMode == .spatial {
                guard let dual = Self.spatialCamera() else {
                    publishMessage("This iPhone can't record spatial video.")
                    applyVideoFormat(announce: false)
                    return
                }
                spatialSession = true
                macroSession = false
                use(dual)
                publishMessage("Spatial video: hold the iPhone sideways, about a metre or more from your subject.")
            } else if leavingSpatial {
                spatialSession = false
                switchToMainCamera()
            } else {
                applyVideoFormat(announce: false)
            }
        } else {
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            if let audioInput { session.removeInput(audioInput) }
            audioInput = nil
            updatePhotoAudio()
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.sessionPreset = .photo
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            session.commitConfiguration()
            if leavingSpatial {
                spatialSession = false
                switchToMainCamera()
            } else if let device {
                use(device)
            }
        }
    }

    /// Back to the main 1× camera. Call on the session queue.
    private func switchToMainCamera() {
        let main = Self.discoverLenses().first { $0.label == "1×" }
        if let main, let camera = AVCaptureDevice(uniqueID: main.id) { use(camera) }
    }

    /// Picks the camera format for the chosen resolution, frame rate and colour. Call on the session queue.
    func applyVideoFormat(announce: Bool) {
        guard let device else { return }
        let settings = DispatchQueue.main.sync {
            (self.videoQuality, self.slowMoRate, self.useLog, self.useProRes, self.hdrVideo, self.stabilization)
        }
        let (quality, rate, wantsLog, wantsProRes, wantsHDR, stabilization) = settings
        let wanted = VideoTarget(width: quality.width, height: quality.height, fps: quality.fps)
        var targets: [VideoTarget]
        switch sessionMode {
        case .slowMo:
            let fps = Double(rate.rawValue)
            targets = [VideoTarget(width: 1920, height: 1080, fps: fps), VideoTarget(width: 1280, height: 720, fps: fps),
                       VideoTarget(width: 1920, height: 1080, fps: 120), VideoTarget(width: 1280, height: 720, fps: 120)]
        case .timeLapse:
            targets = [VideoTarget(width: quality.width, height: quality.height, fps: 30), VideoTarget(width: 1920, height: 1080, fps: 30)]
        case .spatial:
            targets = [VideoTarget(width: 1920, height: 1080, fps: 30), VideoTarget(width: 1920, height: 1080, fps: 24)]
        default:
            targets = [wanted] + VideoQuality.allCases.filter { $0 != quality }.map { VideoTarget(width: $0.width, height: $0.height, fps: $0.fps) }
        }
        // Colour: Apple Log, else HDR (HLG, saved as Dolby Vision), else standard.
        enum Colour { case log, hdr, standard }
        var passes: [Colour] = []
        if sessionMode == .video && wantsLog { passes.append(.log) }
        if sessionMode == .video && wantsHDR && !wantsLog { passes.append(.hdr) }
        passes.append(.standard)
        let spatial = sessionMode == .spatial
        for colour in passes {
            for target in targets {
                let candidates = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    guard dims.width == target.width && dims.height == target.height
                            && format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= target.fps }) else { return false }
                    if spatial && !Self.supportsSpatial(format) { return false }
                    switch colour {
                    case .log: return format.supportedColorSpaces.contains(.appleLog)
                    case .hdr: return format.supportedColorSpaces.contains(.HLG_BT2020)
                    case .standard: return true
                    }
                }
                let subtype = { (format: AVCaptureDevice.Format) in CMFormatDescriptionGetMediaSubType(format.formatDescription) }
                let chosen: AVCaptureDevice.Format?
                switch colour {
                case .log: chosen = candidates.first
                case .hdr: chosen = candidates.first { subtype($0) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange } ?? candidates.first
                // Full-range 8-bit: every iPhone records it.
                case .standard: chosen = candidates.first { subtype($0) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange } ?? candidates.first
                }
                guard let format = chosen else { continue }
                session.beginConfiguration()
                session.sessionPreset = .inputPriority
                session.automaticallyConfiguresCaptureDeviceForWideColor = colour == .standard
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = format
                    switch colour {
                    case .log: device.activeColorSpace = .appleLog
                    case .hdr: device.activeColorSpace = .HLG_BT2020
                    case .standard:
                        if device.activeColorSpace == .appleLog || device.activeColorSpace == .HLG_BT2020 { device.activeColorSpace = .sRGB }
                    }
                    let frame = CMTime(value: 1, timescale: CMTimeScale(target.fps))
                    device.activeVideoMinFrameDuration = frame
                    device.activeVideoMaxFrameDuration = frame
                    device.unlockForConfiguration()
                } catch {
                    session.commitConfiguration()
                    continue
                }
                session.commitConfiguration()
                alignFrameOutput()
                var proResOK = false
                var spatialOn = false
                if let connection = movieOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        var mode = stabilization.mode
                        if spatial { mode = format.isVideoStabilizationModeSupported(.cinematicExtended) ? .cinematicExtended : .standard }
                        if mode != .auto && mode != .off && !format.isVideoStabilizationModeSupported(mode) { mode = .auto }
                        connection.preferredVideoStabilizationMode = mode
                    }
                    if #available(iOS 18.0, *) {
                        if spatial && movieOutput.isSpatialVideoCaptureSupported {
                            movieOutput.isSpatialVideoCaptureEnabled = true
                        } else if movieOutput.isSpatialVideoCaptureEnabled {
                            movieOutput.isSpatialVideoCaptureEnabled = false
                        }
                        spatialOn = movieOutput.isSpatialVideoCaptureEnabled
                    }
                    let codecs = movieOutput.availableVideoCodecTypes
                    proResOK = codecs.contains(.proRes422) || codecs.contains(.proRes422HQ)
                    let codec: AVVideoCodecType?
                    if sessionMode == .video && (wantsProRes || colour == .log) && proResOK {
                        codec = codecs.contains(.proRes422HQ) ? .proRes422HQ : .proRes422
                    } else {
                        codec = codecs.contains(.hevc) ? .hevc : nil
                    }
                    if let codec { movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection) }
                }
                let iso = (format.minISO, format.maxISO)
                let shutter = (max(format.minExposureDuration.seconds, 1.0 / 16000), min(format.maxExposureDuration.seconds, 1.0 / target.fps))
                let maxZoom = min(format.videoMaxZoomFactor, 15)
                let mode = sessionMode
                var label = target.label
                if colour == .log { label += " · LOG" }
                if colour == .hdr { label += " · HDR" }
                if spatialOn { label += " · SPATIAL" }
                if mode == .video && (wantsProRes || colour == .log) && proResOK { label += " · ProRes" }
                let fellBack = target != targets[0] || (colour == .standard && mode == .video && (wantsLog || wantsHDR))
                    || (spatial && !spatialOn)
                DispatchQueue.main.async {
                    self.minISO = iso.0
                    self.maxISO = iso.1
                    self.minShutter = shutter.0
                    self.maxShutter = shutter.1
                    self.maxZoom = maxZoom
                    self.activeFormatLabel = label
                    if mode == .video || mode == .slowMo { self.proResAvailable = proResOK || self.proResAvailable }
                    if mode == .video, target != wanted, let match = VideoQuality.allCases.first(where: {
                        $0.width == target.width && $0.height == target.height && $0.fps == target.fps }) {
                        self.videoQuality = match
                    }
                    if announce && fellBack { self.message = "This camera can't do that; using \(label)." }
                    if self.auto180 || self.program == .shutter || self.program == .iso { self.startPriority() }
                }
                return
            }
        }
        publishMessage("This camera can't record video in these formats.")
    }

    // MARK: Status

    func publishMessage(_ text: String) {
        DispatchQueue.main.async { self.message = text }
    }

    /// Sends the overlay choices to the frame queue.
    func updateAssist() {
        var settings = AssistSettings()
        settings.look = mode == .photo ? look : Look.none.id
        settings.peaking = peaking
        settings.zebras = zebras
        settings.zebraLevel = CGFloat(zebraLevel)
        settings.falseColour = falseColour
        settings.loupe = loupe
        settings.scope = scopeStyle
        settings.detect = detectCodes && mode == .photo
        videoQueue.async { self.assist = settings }
    }
}

/// Small wrapper for remembered settings.
enum Prefs {
    static func key(_ name: String) -> String { "lumen.camera.\(name)" }
    static func bool(_ name: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key(name)) as? Bool ?? fallback
    }
    static func int(_ name: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key(name)) as? Int ?? fallback
    }
    static func double(_ name: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key(name)) as? Double ?? fallback
    }
    static func string(_ name: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key(name)) ?? fallback
    }
    static func set(_ name: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key(name))
    }
}

// MARK: - Recording finished

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let recordedMode = recordingMode
        let fps = device.map { 1 / $0.activeVideoMinFrameDuration.seconds } ?? 30
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingStarted = nil
        }
        // A recording that hit a limit (storage, length) can still have finished properly.
        if let error = error as NSError?,
           (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true {
            publishMessage("Recording failed: \(error.localizedDescription)")
            return
        }
        let place = DispatchQueue.main.sync { self.locationTagging ? self.location.latest : nil }
        Task {
            var url = outputFileURL
            let editable = DispatchQueue.main.sync { self.slowMoEditable }
            if recordedMode == .slowMo, fps > 31, editable {
                // Saved at its full frame rate, sound included: Photos plays it as Slo-mo, and you can move the slow part there.
                self.publishMessage("Slo-mo saved at \(Int(fps.rounded())) fps. In Photos, tap Edit to choose the slow part.")
            } else if recordedMode == .slowMo, fps > 31 {
                self.publishMessage("Making the slow-motion video…")
                if let slow = await Self.slowMotion(outputFileURL, capturedFPS: fps) {
                    url = slow
                    self.publishMessage("Slow motion saved (\(Int(fps.rounded())) fps played at 30, with slowed sound).")
                } else {
                    self.publishMessage("Couldn't slow the video down; saved it at normal speed.")
                }
            }
            await self.saveVideo(url, location: place)
        }
    }

    /// Saves a finished video to Photos and shows it in the thumbnail.
    func saveVideo(_ url: URL, location: CLLocation?) async {
        do {
            try await PhotoSaver.saveVideo(url, location: location)
            let thumbnail = Self.videoThumbnail(url)
            await MainActor.run {
                self.lastVideoURL = url
                self.lastThumbnail = thumbnail
                self.lastWasVideo = true
            }
        } catch {
            publishMessage("Couldn't save the video: \(error.localizedDescription)")
        }
    }

    static func videoThumbnail(_ url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Live frames: overlays, stacking, time-lapse, histogram

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if let writer = timeLapse, writer.append(sampleBuffer) {
            let frames = writer.frameCount
            DispatchQueue.main.async { self.timeLapseFrames = frames }
        }

        if let stacker {
            let done = stacker.add(pixels)
            let progress = Double(stacker.count) / Double(stacker.target)
            DispatchQueue.main.async { if self.stackProgress != nil { self.stackProgress = min(progress, 0.99) } }
            if done {
                self.stacker = nil
                stacker.finish()
            }
            return
        }

        if scanRequested {
            scanRequested = false
            scanDocument(from: pixels)
        }

        let now = Date()
        let settings = assist
        if settings.loupe, now.timeIntervalSince(lastLoupe) >= 1.0 / 15 {
            lastLoupe = now
            let image = frameAssist.renderLoupe(pixels, peakingOn: settings.peaking)
            DispatchQueue.main.async { self.overlay.loupe = image }
        }
        if settings.detect, now.timeIntervalSince(lastDetection) >= 0.4 {
            lastDetection = now
            detect(in: pixels)
        }
        if settings.needsOverlay {
            if now.timeIntervalSince(lastOverlay) >= 1.0 / 20 {
                lastOverlay = now
                let image = frameAssist.render(pixels, settings: settings)
                overlayShown = true
                DispatchQueue.main.async { self.overlay.image = image }
            }
        } else if overlayShown {
            overlayShown = false
            DispatchQueue.main.async { self.overlay.image = nil }
        }

        guard now.timeIntervalSince(lastHistogram) > 0.15 else { return }
        lastHistogram = now
        let bins = Self.lumaHistogram(pixels)
        let rgb = settings.scope == .rgb ? Scopes.rgbHistogram(pixels) : []
        let wave = settings.scope == .waveform ? Scopes.waveform(pixels) : nil
        // While in auto, show what the camera chose.
        let device = self.device
        let iso = device?.iso
        let shutter = device?.exposureDuration.seconds
        let wb = device.map { $0.temperatureAndTintValues(for: $0.deviceWhiteBalanceGains) }
        let lens = device?.lensPosition
        let isMainBack = device?.deviceType == .builtInWideAngleCamera && device?.position == .back
        DispatchQueue.main.async {
            self.histogram = bins
            self.rgbHistogram = rgb
            self.waveform = wave
            if (self.autoExposure || self.program == .shutter || self.program == .iso), let iso, let shutter, shutter.isFinite {
                self.iso = iso
                self.shutter = shutter
            }
            if self.autoWhiteBalance, let wb {
                self.temperature = wb.temperature
                self.tint = wb.tint
            }
            if self.autoFocus, !self.isPulling, let lens { self.lensPosition = lens }
            if let lens { self.checkAutoMacro(lensPosition: lens, onMainBack: isMainBack) }
        }
    }

    /// A 64-bin brightness histogram from the luma plane, sampling every 8th pixel.
    private static func lumaHistogram(_ buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return Array(repeating: 0, count: 64)
        }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var bins = [Float](repeating: 0, count: 64)
        var y = 0
        while y < height {
            let row = bytes + y * stride
            var x = 0
            while x < width {
                bins[Int(row[x]) >> 2] += 1
                x += 8
            }
            y += 8
        }
        let peak = max(1, bins.max() ?? 1)
        return bins.map { $0 / peak }
    }
}
