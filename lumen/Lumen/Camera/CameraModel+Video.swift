import AVFoundation
import UIKit

extension CameraModel {
    // MARK: Recording

    func toggleRecording() {
        if mode == .timeLapse {
            toggleTimeLapse()
            return
        }
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard self.sessionMode.usesMovieFile else { return }
            if let connection = self.movieOutput.connection(with: .video), let coordinator = self.rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
            self.recordingMode = self.sessionMode
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingStarted = Date()
            }
        }
    }

    // MARK: Time-lapse

    private func toggleTimeLapse() {
        if isRecording {
            isRecording = false
            recordingStarted = nil
            let place = locationTagging ? location.latest : nil
            videoQueue.async {
                guard let writer = self.timeLapse else { return }
                self.timeLapse = nil
                writer.finish { url in
                    guard let url else {
                        self.publishMessage("The time-lapse was too short to save.")
                        return
                    }
                    Task { await self.saveVideo(url, location: place) }
                }
            }
            return
        }
        let interval = timeLapseInterval
        timeLapseFrames = 0
        isRecording = true
        recordingStarted = Date()
        sessionQueue.async {
            self.recordingMode = .timeLapse
            let turn = self.captureRotationFromFrames()
            self.videoQueue.async { self.timeLapse = TimeLapseWriter(interval: interval, clockwiseDegrees: turn) }
        }
    }

    // MARK: Audio meters

    func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                let channels = self.movieOutput.connection(with: .audio)?.audioChannels ?? []
                // dB (−60…0) to 0–1.
                let levels = channels.map { max(0, min(1, ($0.averagePowerLevel + 60) / 60)) }
                DispatchQueue.main.async { self.audioMeter.levels = levels }
            }
        }
    }

    func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioMeter.levels = []
    }

    // MARK: Microphone choice

    /// The iPhone's own microphones (bottom, front, back) and anything plugged in or paired.
    func refreshMics() {
        let audio = AVAudioSession.sharedInstance()
        var options: [MicOption] = []
        for port in audio.availableInputs ?? [] {
            if port.portType == .builtInMic, let sources = port.dataSources, !sources.isEmpty {
                for source in sources {
                    options.append(MicOption(id: "\(port.uid)|\(source.dataSourceID)", name: "iPhone – \(source.dataSourceName)",
                                             portUID: port.uid, dataSourceID: source.dataSourceID))
                }
            } else {
                options.append(MicOption(id: port.uid, name: port.portName, portUID: port.uid, dataSourceID: nil))
            }
        }
        micOptions = options
    }

    /// nil = let iOS choose (the default).
    func selectMic(_ option: MicOption?) {
        micID = option?.id
        sessionQueue.async {
            let audio = AVAudioSession.sharedInstance()
            guard let option else {
                self.session.automaticallyConfiguresApplicationAudioSession = true
                try? audio.setPreferredInput(nil)
                return
            }
            self.session.automaticallyConfiguresApplicationAudioSession = false
            do {
                try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
                try audio.setActive(true)
                guard let port = audio.availableInputs?.first(where: { $0.uid == option.portUID }) else {
                    throw CaptureError.failed("That microphone isn't connected.")
                }
                try audio.setPreferredInput(port)
                if let sourceID = option.dataSourceID, let source = port.dataSources?.first(where: { $0.dataSourceID == sourceID }) {
                    try port.setPreferredDataSource(source)
                }
            } catch {
                self.publishMessage("Couldn't switch microphone: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Auto 180° shutter

    /// Video: shutter fixed at half the frame time (1/48 at 24 fps, 1/60 at 30…) for natural motion blur; ISO follows the light.
    func setAuto180(_ on: Bool) {
        auto180 = on
        if on { startAuto180() } else { stopAuto180(); setAutoExposure(true) }
    }

    func startAuto180() {
        guard mode.isVideo else { return }
        autoExposure = false
        aeafLocked = false
        sessionQueue.async {
            self.auto180Timer?.cancel()
            guard let device = self.device, device.isExposureModeSupported(.custom) else { return }
            let fps = 1 / max(device.activeVideoMinFrameDuration.seconds, 1.0 / 240)
            let format = device.activeFormat
            let seconds = max(format.minExposureDuration.seconds, min(format.maxExposureDuration.seconds, 1 / (2 * fps)))
            let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            if (try? device.lockForConfiguration()) != nil {
                device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.currentISO, completionHandler: nil)
                device.unlockForConfiguration()
            }
            let timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            timer.schedule(deadline: .now() + 0.3, repeating: 0.2)
            timer.setEventHandler { [weak self] in
                guard let self, let device = self.device, device.exposureMode == .custom else { return }
                let offset = device.exposureTargetOffset - device.exposureTargetBias
                guard offset.isFinite, abs(offset) > 0.1 else { return }
                // Move part of the way each time so changes look smooth.
                let target = device.iso * pow(2, -offset * 0.5)
                let iso = max(device.activeFormat.minISO, min(device.activeFormat.maxISO, target))
                if (try? device.lockForConfiguration()) != nil {
                    device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                    device.unlockForConfiguration()
                }
            }
            self.auto180Timer = timer
            timer.resume()
        }
    }

    func stopAuto180() {
        auto180 = false
        sessionQueue.async {
            self.auto180Timer?.cancel()
            self.auto180Timer = nil
        }
    }

    // MARK: Focus pull

    /// Remembers the current focus as mark A (0) or B (1).
    func setFocusMark(_ mark: Int) {
        if autoFocus { setLensPosition(lensPosition) }
        if mark == 0 { focusA = lensPosition } else { focusB = lensPosition }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Smoothly racks focus to whichever mark is further away.
    func pullFocus() {
        guard let a = focusA, let b = focusB, !isPulling else { return }
        let start = lensPosition
        let end = abs(start - a) < abs(start - b) ? b : a
        let duration = max(0.3, focusPullSeconds)
        let began = Date()
        isPulling = true
        pullTimer?.invalidate()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let eased = Float(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
            self.setLensPosition(start + (end - start) * eased)
            if t >= 1 {
                timer.invalidate()
                self.isPulling = false
            }
        }
    }

    // MARK: Slow motion

    /// Stretches a high-frame-rate clip so it plays back at 30 fps (every captured frame shown). The sound is left out.
    static func slowMotion(_ url: URL, capturedFPS: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let duration = try await asset.load(.duration)
            let transform = try await track.load(.preferredTransform)
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: track, at: .zero)
            videoTrack.preferredTransform = transform
            composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: capturedFPS / 30))
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
                    ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-slomo-\(UUID().uuidString).mov")
            export.outputURL = output
            export.outputFileType = .mov
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { continuation.resume() }
            }
            return export.status == .completed ? output : nil
        } catch {
            return nil
        }
    }
}

/// Writes one frame every few seconds into a 30 fps video. Runs on the frame queue.
final class TimeLapseWriter {
    private let interval: Double
    private let degrees: CGFloat
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-timelapse-\(UUID().uuidString).mov")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastTaken: CMTime = .invalid
    private(set) var frameCount = 0
    private var failed = false

    init(interval: Double, clockwiseDegrees: CGFloat) {
        self.interval = interval
        self.degrees = clockwiseDegrees
    }

    /// Returns true when the frame was used.
    func append(_ sample: CMSampleBuffer) -> Bool {
        guard !failed, let buffer = CMSampleBufferGetImageBuffer(sample) else { return false }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if lastTaken.isValid, CMTimeSubtract(time, lastTaken).seconds < interval { return false }
        if writer == nil { setUp(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
        guard let input, let adaptor, input.isReadyForMoreMediaData else { return false }
        lastTaken = time
        if adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameCount), timescale: 30)) {
            frameCount += 1
            return true
        }
        return false
    }

    private func setUp(width: Int, height: Int) {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
            input.expectsMediaDataInRealTime = true
            input.transform = Self.transform(clockwiseDegrees: degrees, width: CGFloat(width), height: CGFloat(height))
            guard writer.canAdd(input) else { failed = true; return }
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else { failed = true; return }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        } catch {
            failed = true
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        guard let writer, let input, frameCount > 1 else {
            writer?.cancelWriting()
            completion(nil)
            return
        }
        let url = self.url
        input.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? url : nil)
        }
    }

    /// The video's display rotation (frames are stored as the preview showed them).
    static func transform(clockwiseDegrees: CGFloat, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch ((Int((clockwiseDegrees / 90).rounded()) % 4) + 4) % 4 {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: return .identity
        }
    }
}
