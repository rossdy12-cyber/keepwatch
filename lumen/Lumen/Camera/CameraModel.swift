import AVFoundation
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

enum CaptureMode: String {
    case photo = "PHOTO", video = "VIDEO"
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

/// The camera: lenses, manual controls, capture and saving.
/// Session work runs on its own queue; anything the screen shows is published on the main thread.
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lumen.camera.session")
    private let videoQueue = DispatchQueue(label: "lumen.camera.frames")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var audioInput: AVCaptureDeviceInput?
    /// The mode the session is set up for (only touched on the session queue).
    private var sessionMode: CaptureMode = .photo
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var processors: [Int64: PhotoProcessor] = [:]
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationObservation: NSKeyValueObservation?
    private var lastHistogram = Date.distantPast
    private var configured = false

    // What the screen shows.
    @Published var authorised = true
    @Published var lenses: [Lens] = []
    @Published var currentLensID: String?
    @Published var format: CaptureFormat = .heif
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

    @Published var mode: CaptureMode = .photo
    @Published var videoQuality: VideoQuality = .uhd30
    @Published var isRecording = false
    @Published var recordingStarted: Date?
    @Published var lastVideoURL: URL?
    @Published var lastWasVideo = false

    @Published var histogram: [Float] = Array(repeating: 0, count: 64)
    @Published var lastThumbnail: UIImage?
    @Published var lastAssetID: String?
    @Published var isCapturing = false
    @Published var message: String?

    // MARK: Starting and stopping

    func start() {
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
        configured = true
        use(camera)
    }

    /// Every physical camera (manual controls only work on the physical ones, not the combined "virtual" camera).
    private static func discoverLenses() -> [Lens] {
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

    func selectLens(_ lens: Lens) {
        sessionQueue.async {
            guard lens.id != self.device?.uniqueID, let camera = AVCaptureDevice(uniqueID: lens.id) else { return }
            self.use(camera)
        }
    }

    /// Switches to a camera. Call on the session queue.
    private func use(_ camera: AVCaptureDevice) {
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
        // Full-resolution photos from this camera.
        if let largest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        session.commitConfiguration()
        makeRotationCoordinator()
        if sessionMode == .video { applyVideoFormat(announce: false) }
        let base = lenses(matching: camera.uniqueID)

        let rawFormats = photoOutput.availableRawPhotoPixelFormatTypes
        let proRAW = rawFormats.contains { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let anyRAW = !rawFormats.isEmpty
        let snapshot = (
            id: camera.uniqueID,
            minISO: camera.activeFormat.minISO, maxISO: camera.activeFormat.maxISO,
            minShutter: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 16000),
            maxShutter: min(camera.activeFormat.maxExposureDuration.seconds, 1.0),
            minBias: camera.minExposureTargetBias, maxBias: camera.maxExposureTargetBias,
            maxZoom: min(camera.maxAvailableVideoZoomFactor, 15),
            flash: camera.hasFlash, manualFocus: camera.isLockingFocusWithCustomLensPositionSupported
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
            self.proRAW = proRAW
            self.rawAvailable = anyRAW
            if !anyRAW && (self.format == .raw || self.format == .rawPlusHEIF) { self.format = .heif }
            self.zoom = 1
            self.lensBase = base
            // A new camera starts in auto; manual values are per-camera.
            self.autoExposure = true
            self.autoWhiteBalance = true
            self.autoFocus = true
            self.exposureBias = 0
        }
    }

    /// The zoom of a lens relative to the main camera, from the discovered list.
    private func lenses(matching id: String) -> Double {
        let found = Self.discoverLenses().first { $0.id == id }
        guard let found else { return 1 }
        return found.position == .front ? 1 : found.order
    }

    private func makeRotationCoordinator() {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        // The screen stays portrait; the preview always shows the scene upright.
        DispatchQueue.main.async {
            self.previewLayer?.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            self.rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.previewLayer?.connection?.videoRotationAngle = angle }
            }
        }
    }

    // MARK: Manual controls

    private func configureDevice(_ change: @escaping (AVCaptureDevice) throws -> Void) {
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
        if on {
            configureDevice { device in
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
        } else {
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
        applyManualExposure()
    }

    func setShutter(_ seconds: Double) {
        shutter = seconds
        autoExposure = false
        applyManualExposure()
    }

    private func applyManualExposure() {
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

    /// Tap to focus and expose at a point (0–1 device coordinates).
    func focus(at point: CGPoint) {
        DispatchQueue.main.async {
            self.autoFocus = true
            if !self.autoExposure { self.autoExposure = true }
        }
        configureDevice { device in
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
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
            selectLens(main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.setEffectiveZoom(effective) }
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

    // MARK: Video

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording else { return }
        mode = newMode
        if newMode == .video && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.applyMode(newMode) }
            }
        } else {
            sessionQueue.async { self.applyMode(newMode) }
        }
    }

    func setVideoQuality(_ quality: VideoQuality) {
        videoQuality = quality
        sessionQueue.async { self.applyVideoFormat(announce: true) }
    }

    /// Call on the session queue.
    private func applyMode(_ newMode: CaptureMode) {
        sessionMode = newMode
        session.beginConfiguration()
        if newMode == .video {
            // The histogram feed is swapped for the movie recorder.
            if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioInput = micInput
            }
            session.commitConfiguration()
            applyVideoFormat(announce: false)
        } else {
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            if let audioInput { session.removeInput(audioInput) }
            audioInput = nil
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.sessionPreset = .photo
            session.commitConfiguration()
            if let device { use(device) }
        }
    }

    /// Picks the camera format for the chosen resolution and frame rate. Call on the session queue.
    private func applyVideoFormat(announce: Bool) {
        guard let device else { return }
        let wanted = DispatchQueue.main.sync { self.videoQuality }
        let qualities = [wanted] + VideoQuality.allCases.filter { $0 != wanted }
        for quality in qualities {
            let candidates = device.formats.filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == quality.width && dims.height == quality.height
                    && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= quality.fps }
            }
            // Prefer full-range 8-bit, which every iPhone records.
            let chosen = candidates.first { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange }
                ?? candidates.first
            guard let format = chosen else { continue }
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let frame = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
                device.activeVideoMinFrameDuration = frame
                device.activeVideoMaxFrameDuration = frame
                device.unlockForConfiguration()
            } catch {
                session.commitConfiguration()
                continue
            }
            session.commitConfiguration()
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .auto }
                if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }
            }
            let iso = (format.minISO, format.maxISO)
            let shutter = (max(format.minExposureDuration.seconds, 1.0 / 16000), min(format.maxExposureDuration.seconds, 1.0 / quality.fps))
            let maxZoom = min(format.videoMaxZoomFactor, 15)
            DispatchQueue.main.async {
                self.minISO = iso.0
                self.maxISO = iso.1
                self.minShutter = shutter.0
                self.maxShutter = shutter.1
                self.maxZoom = maxZoom
                if quality != wanted {
                    self.videoQuality = quality
                    if announce { self.message = "This camera can't do \(wanted.rawValue); using \(quality.rawValue)." }
                }
            }
            return
        }
        publishMessage("This camera can't record video in these formats.")
    }

    func toggleRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard self.sessionMode == .video else { return }
            if let connection = self.movieOutput.connection(with: .video), let coordinator = self.rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingStarted = Date()
            }
        }
    }

    // MARK: Taking a photo

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        let format = self.format
        let flash = self.flash
        sessionQueue.async {
            let settings = self.makeSettings(format: format, flash: flash)
            if let connection = self.photoOutput.connection(with: .video), let coordinator = self.rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
            let id = settings.uniqueID
            let processor = PhotoProcessor { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { self.processors[id] = nil }
                DispatchQueue.main.async {
                    self.isCapturing = false
                    switch result {
                    case .success(let saved):
                        self.lastThumbnail = saved.thumbnail
                        self.lastAssetID = saved.assetID
                        self.lastWasVideo = false
                    case .failure(let error):
                        self.message = error.localizedDescription
                    }
                }
            }
            self.processors[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func makeSettings(format: CaptureFormat, flash: AVCaptureDevice.FlashMode) -> AVCapturePhotoSettings {
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let rawType = rawTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            ?? rawTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let hevc = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let processed: [String: Any] = [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg]

        let settings: AVCapturePhotoSettings
        var isBayer = false
        switch format {
        case .raw where rawType != nil:
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType!)
            isBayer = AVCapturePhotoOutput.isBayerRAWPixelFormat(rawType!)
        case .rawPlusHEIF where rawType != nil:
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType!, processedFormat: processed)
            isBayer = AVCapturePhotoOutput.isBayerRAWPixelFormat(rawType!)
        case .jpeg:
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        default:
            settings = AVCapturePhotoSettings(format: processed)
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // Bayer RAW is the sensor's data as it is: no multi-frame processing or flash.
        if !isBayer {
            settings.photoQualityPrioritization = .quality
            if photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        }
        return settings
    }

    // MARK: Live readouts and histogram

    private func publishMessage(_ text: String) {
        DispatchQueue.main.async { self.message = text }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
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
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.publishMessage(CaptureError.noPhotosAccess.localizedDescription)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: outputFileURL, options: nil)
            }) { success, error in
                let thumbnail = Self.videoThumbnail(outputFileURL)
                DispatchQueue.main.async {
                    if success {
                        self.lastVideoURL = outputFileURL
                        self.lastThumbnail = thumbnail
                        self.lastWasVideo = true
                    } else {
                        self.message = "Couldn't save the video: \(error?.localizedDescription ?? "unknown error")"
                    }
                }
            }
        }
    }

    private static func videoThumbnail(_ url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastHistogram) > 0.15, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastHistogram = now
        let bins = Self.lumaHistogram(pixels)
        // While in auto, show what the camera chose.
        let device = self.device
        let iso = device?.iso
        let shutter = device?.exposureDuration.seconds
        let wb = device.map { $0.temperatureAndTintValues(for: $0.deviceWhiteBalanceGains) }
        let lens = device?.lensPosition
        DispatchQueue.main.async {
            self.histogram = bins
            if self.autoExposure, let iso, let shutter, shutter.isFinite {
                self.iso = iso
                self.shutter = shutter
            }
            if self.autoWhiteBalance, let wb {
                self.temperature = wb.temperature
                self.tint = wb.tint
            }
            if self.autoFocus, let lens { self.lensPosition = lens }
        }
    }

    /// A 64-bin brightness histogram from the luma plane, sampling every 8th pixel.
    private static func lumaHistogram(_ buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return Array(repeating: 0, count: 64) }
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
