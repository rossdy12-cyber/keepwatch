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
    case ev = "EV", iso = "ISO", shutter = "S", whiteBalance = "WB", focus = "F"
    var id: String { rawValue }
}

/// The camera: lenses, manual controls, capture and saving.
/// Session work runs on its own queue; anything the screen shows is published on the main thread.
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lumen.camera.session")
    private let videoQueue = DispatchQueue(label: "lumen.camera.frames")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
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
            // A new camera starts in auto; manual values are per-camera.
            self.autoExposure = true
            self.autoWhiteBalance = true
            self.autoFocus = true
            self.exposureBias = 0
        }
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

    func setZoom(_ factor: CGFloat) {
        let clamped = max(1, min(maxZoom, factor))
        zoom = clamped
        configureDevice { device in
            device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(device.maxAvailableVideoZoomFactor, clamped))
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
