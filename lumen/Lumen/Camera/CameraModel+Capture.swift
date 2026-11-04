import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

extension CameraModel {
    // MARK: The shutter

    /// One press of the shutter in photo mode, whatever the drive.
    func capture() {
        switch drive {
        case .night: captureStack(longExposure: false)
        case .longExposure: captureStack(longExposure: true)
        case .hdr: captureHDR()
        case .interval: toggleInterval()
        default: capturePhoto()
        }
    }

    /// Shape, location and look for a new photo (read on the main thread).
    func saveOptions(withLook: Bool = true) -> SaveOptions {
        SaveOptions(aspect: aspect,
                    location: locationTagging ? location.latest : nil,
                    look: withLook ? look : Look.none.id,
                    allowCrop: drive != .portrait)
    }

    /// A single photo. `inSequence` (burst, interval) skips the one-at-a-time guard and the slow processing.
    func capturePhoto(inSequence: Bool = false) {
        if !inSequence {
            guard !isCapturing else { return }
            isCapturing = true
        }
        let portrait = drive == .portrait
        let chosen: CaptureFormat = inSequence || portrait ? (format == .jpeg ? .jpeg : .heif) : format
        let flash: AVCaptureDevice.FlashMode = inSequence ? .off : self.flash
        let options = saveOptions(withLook: drive != .burst)
        sessionQueue.async {
            self.shootPhoto(format: chosen, flash: flash, speed: inSequence, options: options) { [weak self] result in
                guard let self else { return }
                DispatchQueue.main.async {
                    if !inSequence { self.isCapturing = false }
                    self.show(result)
                }
            }
        }
    }

    /// Call on the session queue.
    func shootPhoto(format: CaptureFormat, flash: AVCaptureDevice.FlashMode, speed: Bool, options: SaveOptions,
                    completion: @escaping (Result<SavedPhoto, Error>) -> Void) {
        let settings = makeSettings(format: format, flash: flash, speed: speed)
        rotatePhotoConnection()
        let id = settings.uniqueID
        let processor = PhotoProcessor(options: options) { [weak self] result in
            self?.sessionQueue.async { self?.processors[id] = nil }
            completion(result)
        }
        processors[id] = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    func show(_ result: Result<SavedPhoto, Error>) {
        switch result {
        case .success(let saved):
            if let thumbnail = saved.thumbnail { lastThumbnail = thumbnail }
            lastAssetID = saved.assetID
            lastWasVideo = false
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    func rotatePhotoConnection() {
        if let connection = photoOutput.connection(with: .video), let coordinator = rotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    func makeSettings(format: CaptureFormat, flash: AVCaptureDevice.FlashMode, speed: Bool = false) -> AVCapturePhotoSettings {
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
        if !speed { settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions }
        // Bayer RAW is the sensor's data as it is: no multi-frame processing or flash.
        if !isBayer {
            settings.photoQualityPrioritization = speed ? .speed : .quality
            if photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        }
        // Portrait: depth and the person cut-out go into the photo, for background blur in the editor.
        if photoOutput.isDepthDataDeliveryEnabled && (format == .heif || format == .jpeg) {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true
            if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
                settings.embedsPortraitEffectsMatteInPhoto = true
            }
        }
        return settings
    }

    // MARK: Burst

    func startBurst() {
        guard !isBursting, mode == .photo else { return }
        isBursting = true
        burstTaken = 0
        let options = saveOptions(withLook: false)
        let format: CaptureFormat = self.format == .jpeg ? .jpeg : .heif
        sessionQueue.async {
            self.burstInFlight = 0
            let timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(110))
            timer.setEventHandler { [weak self] in
                guard let self, self.burstInFlight < 3 else { return }
                self.burstInFlight += 1
                DispatchQueue.main.async {
                    self.burstTaken += 1
                    if self.burstTaken >= 200 { self.stopBurst() }
                }
                self.shootPhoto(format: format, flash: .off, speed: true, options: options) { [weak self] result in
                    self?.sessionQueue.async { self?.burstInFlight -= 1 }
                    DispatchQueue.main.async { self?.show(result) }
                }
            }
            self.burstTimer = timer
            timer.resume()
        }
    }

    func stopBurst() {
        guard isBursting else { return }
        isBursting = false
        let taken = burstTaken
        sessionQueue.async {
            self.burstTimer?.cancel()
            self.burstTimer = nil
        }
        if taken > 1 { message = "Burst: \(taken) photos saved." }
    }

    // MARK: Interval timer

    func toggleInterval() {
        if intervalRunning {
            intervalTimer?.invalidate()
            intervalTimer = nil
            intervalRunning = false
            message = "Interval finished: \(intervalTaken) photos."
            return
        }
        intervalTaken = 0
        intervalRunning = true
        let fire = { [weak self] in
            guard let self, self.intervalRunning else { return }
            self.capturePhoto(inSequence: true)
            self.intervalTaken += 1
            if self.intervalShots > 0 && self.intervalTaken >= self.intervalShots { self.toggleInterval() }
        }
        fire()
        intervalTimer = Timer.scheduledTimer(withTimeInterval: max(1, intervalSeconds), repeats: true) { _ in fire() }
    }

    // MARK: Night and long exposure (stacked live frames)

    func captureStack(longExposure: Bool) {
        guard stackProgress == nil, !isCapturing else { return }
        isCapturing = true
        stackProgress = 0
        let frames = longExposure ? Int(longExposureSeconds * 30) : 12
        let blend: FrameStacker.Blend = longExposure && longExposureStyle == .trails ? .lighten : .average
        let align = !longExposure || !onTripod
        let options = saveOptions()
        sessionQueue.async {
            let turn = self.captureRotationFromFrames()
            self.videoQueue.async {
                self.stacker = FrameStacker(frames: frames, blend: blend, align: align) { [weak self] image in
                    DispatchQueue.global(qos: .userInitiated).async {
                        self?.saveStacked(image, turn: turn, options: options)
                    }
                }
            }
        }
    }

    private func saveStacked(_ image: CIImage?, turn: CGFloat, options: SaveOptions) {
        guard let image else {
            finishStack(.failure(CaptureError.failed("That shot didn't work. Try again.")))
            return
        }
        let upright = StackMath.rotated(image, clockwiseDegrees: turn)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let heif = PhotoSaver.context.heifRepresentation(of: upright, format: .RGBA8, colorSpace: space,
                                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else {
            finishStack(.failure(CaptureError.failed("Couldn't make the photo.")))
            return
        }
        save(heif, extras: [], options: options)
    }

    /// Saves a finished (stacked or merged) photo, then the optional extra frames.
    private func save(_ data: Data, extras: [Data], options: SaveOptions) {
        Task {
            do {
                let shaped = options.allowCrop ? PhotoSaver.crop(data, to: options.aspect) : data
                let id = try await PhotoSaver.savePhoto([(.photo, shaped)], location: options.location)
                for frame in extras { _ = try? await PhotoSaver.savePhoto([(.photo, frame)], location: options.location) }
                finishStack(.success(SavedPhoto(assetID: id, thumbnail: PhotoSaver.thumbnail(shaped, look: options.look))))
                if let id { await PhotoSaver.applyLook(options.look, toAsset: id) }
            } catch {
                finishStack(.failure(error))
            }
        }
    }

    private func finishStack(_ result: Result<SavedPhoto, Error>) {
        DispatchQueue.main.async {
            self.stackProgress = nil
            self.isCapturing = false
            self.show(result)
        }
    }

    // MARK: HDR bracket

    func captureHDR() {
        guard !isCapturing else { return }
        isCapturing = true
        stackProgress = 0.3
        let options = saveOptions()
        let keep = keepBracketFrames
        let manual = !autoExposure
        let iso = self.iso, shutter = self.shutter
        sessionQueue.async {
            guard self.photoOutput.maxBracketedCapturePhotoCount >= 3, let device = self.device else {
                DispatchQueue.main.async {
                    self.stackProgress = nil
                    self.isCapturing = false
                    self.message = "This camera can't bracket; took a normal photo."
                    self.capturePhoto()
                }
                return
            }
            let stops: [Float] = [-2, 0, 2]
            let brackets: [AVCaptureBracketedStillImageSettings]
            if manual {
                let format = device.activeFormat
                brackets = stops.map { stop in
                    let seconds = max(format.minExposureDuration.seconds, min(format.maxExposureDuration.seconds, shutter * pow(2, Double(stop))))
                    return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                        exposureDuration: CMTime(seconds: seconds, preferredTimescale: 1_000_000), iso: max(format.minISO, min(format.maxISO, iso)))
                }
            } else {
                brackets = stops.map {
                    AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                        exposureTargetBias: max(device.minExposureTargetBias, min(device.maxExposureTargetBias, $0)))
                }
            }
            let hevc = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: 0,
                processedFormat: [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg],
                bracketedSettings: brackets)
            settings.photoQualityPrioritization = .speed
            self.rotatePhotoConnection()
            let id = settings.uniqueID
            let processor = BracketProcessor { [weak self] frames, error in
                guard let self else { return }
                self.sessionQueue.async { self.processors[id] = nil }
                DispatchQueue.main.async { self.stackProgress = 0.7 }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.mergeBracket(frames.map { $0.data }, error: error, keep: keep, options: options)
                }
            }
            self.processors[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func mergeBracket(_ frames: [Data], error: Error?, keep: Bool, options: SaveOptions) {
        let images = frames.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
            .map { $0.transformed(by: CGAffineTransform(translationX: -$0.extent.minX, y: -$0.extent.minY)) }
        guard images.count >= 3 else {
            finishStack(.failure(error ?? CaptureError.failed("The bracket didn't come out. Try again.")))
            return
        }
        let normal = images[1]
        let merged = StackMath.mergeHDR(dark: images[0], normal: normal, bright: images[2], context: PhotoSaver.context)
        var properties = normal.properties
        properties[kCGImagePropertyOrientation as String] = 1
        let space = normal.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let heif = PhotoSaver.context.heifRepresentation(of: merged.settingProperties(properties), format: .RGBA8, colorSpace: space,
                                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else {
            finishStack(.failure(CaptureError.failed("Couldn't merge the HDR photo.")))
            return
        }
        save(heif, extras: keep ? frames : [], options: options)
    }

    // MARK: Drive modes, portrait and macro

    func setDrive(_ newDrive: DriveMode) {
        guard !intervalRunning, !isBursting, newDrive != drive else { return }
        let wasPortrait = drive == .portrait
        drive = newDrive
        if newDrive == .portrait {
            enterPortrait()
        } else if wasPortrait {
            leavePortrait()
        }
    }

    private func enterPortrait() {
        sessionQueue.async {
            let front = self.device?.position == .front
            let depthCamera = front
                ? AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                : (AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back))
            guard let depthCamera else {
                DispatchQueue.main.async {
                    self.drive = .single
                    self.message = "This camera can't record depth."
                }
                return
            }
            self.portraitSession = true
            self.macroSession = false
            self.use(depthCamera)
            if !self.photoOutput.isDepthDataDeliveryEnabled {
                self.publishMessage("Depth isn't available here; photos will use the AI cut-out instead.")
            }
        }
    }

    private func leavePortrait() {
        let front = currentDeviceIsFront
        let target = front ? lenses.first { $0.position == .front } : lenses.first { $0.label == "1×" }
        sessionQueue.async {
            self.portraitSession = false
            guard let target, let camera = AVCaptureDevice(uniqueID: target.id) else { return }
            self.use(camera)
        }
    }

    var currentDeviceIsFront: Bool {
        guard let id = currentLensID else { return false }
        return AVCaptureDevice(uniqueID: id)?.position == .front
    }

    var macroAvailable: Bool {
        mode == .photo && drive != .portrait && lenses.contains { $0.label == "0.5×" }
            && (macroActive || currentLensID == lenses.first { $0.label == "1×" }?.id)
    }

    /// Macro: the ultra-wide (which can focus a couple of centimetres away), cropped to frame like the main camera.
    func setMacro(_ on: Bool, automatic: Bool = false) {
        guard let ultra = lenses.first(where: { $0.label == "0.5×" }), let main = lenses.first(where: { $0.label == "1×" }) else { return }
        macroWasAutomatic = on && automatic
        macroCloseTicks = 0
        macroFarTicks = 0
        sessionQueue.async {
            self.macroSession = on
            guard let camera = AVCaptureDevice(uniqueID: on ? ultra.id : main.id) else { return }
            if on {
                // Frame like 1× on the main camera.
                self.use(camera, zoom: CGFloat(1 / max(ultra.order, 0.1)))
            } else {
                self.use(camera)
            }
        }
        if automatic { message = on ? "Macro on: very close subject." : nil }
    }

    /// Auto macro: switch when the main camera is focused as close as it can go, and back once the subject moves away.
    func checkAutoMacro(lensPosition: Float, onMainBack: Bool) {
        guard autoMacro, mode == .photo, drive != .portrait, autoFocus, !aeafLocked, !isCapturing else {
            macroCloseTicks = 0
            return
        }
        if !macroActive, onMainBack, zoom < 1.5 {
            macroCloseTicks = lensPosition <= 0.02 ? macroCloseTicks + 1 : 0
            if macroCloseTicks >= 8 { setMacro(true, automatic: true) }
        } else if macroActive, macroWasAutomatic {
            macroFarTicks = lensPosition >= 0.4 ? macroFarTicks + 1 : 0
            if macroFarTicks >= 10 { setMacro(false, automatic: true) }
        }
    }

    // MARK: Custom presets (C1–C3)

    func savePreset(_ slot: Int) {
        let lens = lenses.first { $0.id == currentLensID }?.label ?? "1×"
        CameraPreset(mode: mode.rawValue, drive: drive.rawValue, format: format.rawValue, videoQuality: videoQuality.rawValue,
                     lensLabel: lens, effectiveZoom: effectiveZoom, autoExposure: autoExposure, iso: iso, shutter: shutter,
                     exposureBias: exposureBias, autoWhiteBalance: autoWhiteBalance, temperature: temperature, tint: tint,
                     autoFocus: autoFocus, lensPosition: lensPosition, look: look, aspect: aspect.rawValue).save(slot)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        message = "Saved as C\(slot)."
    }

    func recallPreset(_ slot: Int) {
        guard let preset = CameraPreset.load(slot) else {
            message = "C\(slot) is empty. Long-press it to save the current settings."
            return
        }
        guard !isRecording, !intervalRunning, !isBursting else { return }
        if let newMode = CaptureMode(rawValue: preset.mode) { setMode(newMode) }
        if let newDrive = DriveMode(rawValue: preset.drive) { setDrive(newDrive) }
        if let newFormat = CaptureFormat(rawValue: preset.format) { format = newFormat }
        if let quality = VideoQuality(rawValue: preset.videoQuality), quality != videoQuality { setVideoQuality(quality) }
        look = preset.look
        if let shape = CaptureAspect(rawValue: preset.aspect) { aspect = shape }
        if drive != .portrait {
            if let lens = lenses.first(where: { $0.label == preset.lensLabel }) {
                let base = lens.label == "0.5×" ? 0.5 : (lens.label == "1×" ? 1 : lens.order)
                sessionQueue.async {
                    self.macroSession = false
                    guard let camera = AVCaptureDevice(uniqueID: lens.id) else { return }
                    self.use(camera, zoom: CGFloat(preset.effectiveZoom / max(base, 0.1)))
                }
            }
        }
        // Manual settings once the camera has switched (a new camera starts in auto).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if preset.autoExposure {
                self.setAutoExposure(true)
            } else {
                self.iso = preset.iso
                self.shutter = preset.shutter
                self.autoExposure = false
                self.applyManualExposure()
            }
            self.setExposureBias(preset.exposureBias)
            if preset.autoWhiteBalance { self.setAutoWhiteBalance(true) } else { self.setWhiteBalance(temperature: preset.temperature, tint: preset.tint) }
            if preset.autoFocus { self.setAutoFocus(true) } else { self.setLensPosition(preset.lensPosition) }
            self.message = "C\(slot) loaded."
        }
    }

    // MARK: Camera Control (iPhone 16) sliders

    /// Zoom, exposure and look on the Camera Control button. Call on the session queue, inside a configuration.
    func installSystemControls(for camera: AVCaptureDevice) {
        if #available(iOS 18.0, *) {
            installControls18(for: camera)
        }
    }

    @available(iOS 18.0, *)
    private func installControls18(for camera: AVCaptureDevice) {
        guard session.supportsControls else { return }
        if controlsHelper == nil {
            let helper = CaptureControlsHelper()
            controlsHelper = helper
            session.setControlsDelegate(helper, queue: sessionQueue)
        }
        for control in session.controls { session.removeControl(control) }
        let zoomSlider = AVCaptureSystemZoomSlider(device: camera) { [weak self] factor in
            DispatchQueue.main.async { self?.zoom = factor }
        }
        let biasSlider = AVCaptureSystemExposureBiasSlider(device: camera) { [weak self] bias in
            DispatchQueue.main.async { self?.exposureBias = bias }
        }
        let looks = AVCaptureIndexPicker("Look", symbolName: "camera.filters", localizedIndexTitles: Look.all.map(\.name))
        let current = DispatchQueue.main.sync { self.look }
        if let index = Look.all.firstIndex(where: { $0.id == current }) { looks.selectedIndex = index }
        looks.setActionQueue(.main) { [weak self] index in
            guard index >= 0, index < Look.all.count else { return }
            self?.look = Look.all[index].id
        }
        for control in [zoomSlider, biasSlider, looks] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
    }
}

@available(iOS 18.0, *)
final class CaptureControlsHelper: NSObject, AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
