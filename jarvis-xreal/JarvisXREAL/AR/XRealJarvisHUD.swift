import AVFoundation
import Combine
import CoreFoundation
import CoreMotion
import Darwin
import SwiftUI
import UIKit
import Vision

// MARK: - Live Homelab & Security Telemetry Store for XREAL HUD Wings

struct ARCameraInfo: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

struct ARCameraEvent: Identifiable, Codable, Hashable {
    var id: String
    var camera: String
    var label: String
    var startTime: Double
    var score: Int

    enum CodingKeys: String, CodingKey {
        case id, camera, label, score
        case startTime = "start_time"
    }

    var formattedTime: String {
        guard startTime > 0 else { return "" }
        let d = Date(timeIntervalSince1970: startTime)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

struct ARContainerSummary: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var state: String
    var status: String
}

@MainActor
final class ARTelemetryStore: ObservableObject {
    static let shared = ARTelemetryStore()

    @Published var runningContainers: Int = 0
    @Published var totalContainers: Int = 0
    @Published var topContainers: [ARContainerSummary] = []
    @Published var desktopOllamaOnline: Bool = false
    @Published var alertsEnabled: Bool = true
    @Published var cameras: [ARCameraInfo] = [
        ARCameraInfo(id: "doorbell", name: "Front Doorbell"),
        ARCameraInfo(id: "reolink_cam", name: "Garden / Reolink")
    ]
    @Published var cameraEvents: [ARCameraEvent] = []
    @Published var snapshotBuster: Int = Int(Date().timeIntervalSince1970)

    private var baseURL: String {
        let addr = ServerAddress.normalize(JarvisSettings.shared.config.address)
        return addr.isEmpty ? "https://jarvis.nas-server.co.uk" : addr
    }

    private func authedRequest(path: String, method: String = "GET") -> URLRequest? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        let secrets = JarvisSettings.shared.secrets
        if !secrets.token.isEmpty {
            req.setValue("Bearer \(secrets.token)", forHTTPHeaderField: "Authorization")
        }
        if !secrets.cfClientID.isEmpty && !secrets.cfClientSecret.isEmpty {
            req.setValue(secrets.cfClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secrets.cfClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return req
    }

    private func session() -> URLSession {
        let host = URL(string: baseURL)?.host
        TrustDelegate.shared.setTrusted(host: host, trusted: JarvisSettings.shared.config.trustSelfSigned)
        return httpSession
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadContainers() }
            group.addTask { await self.loadCameras() }
            group.addTask { await self.loadSystemBridge() }
        }
    }

    func loadContainers() async {
        struct Resp: Decodable {
            let containers: [ARContainerSummary]
        }
        guard let req = authedRequest(path: "/api/keepwatch/containers") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            totalContainers = decoded.containers.count
            runningContainers = decoded.containers.filter { $0.state.lowercased() == "running" }.count
            topContainers = Array(decoded.containers.prefix(8))
        }
    }

    func loadCameras() async {
        struct Resp: Decodable {
            let alerts_enabled: Bool?
            let cameras: [ARCameraInfo]?
            let events: [ARCameraEvent]?
        }
        guard let req = authedRequest(path: "/api/keepwatch/cameras") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            alertsEnabled = decoded.alerts_enabled ?? true
            if let cams = decoded.cameras, !cams.isEmpty {
                cameras = cams
            }
            cameraEvents = decoded.events ?? []
            snapshotBuster = Int(Date().timeIntervalSince1970)
        }
    }

    func loadSystemBridge() async {
        struct Resp: Decodable {
            let desktop_ollama_online: Bool?
        }
        guard let req = authedRequest(path: "/api/keepwatch/system-bridge") else { return }
        if let (data, _) = try? await session().data(for: req),
           let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            desktopOllamaOnline = decoded.desktop_ollama_online ?? false
        }
    }

    func snapshotURL(for camera: String) -> URL? {
        let token = JarvisSettings.shared.secrets.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "\(baseURL)/api/keepwatch/camera/\(camera)/snapshot?token=\(token)&t=\(snapshotBuster)")
    }
}

// MARK: - Native XREAL USB-C HID IMU Driver (VID 0x3318, Interface 3, 1000Hz Gyro/Accel)

private typealias IOHIDReportCallbackFn = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafeMutableRawPointer?,
    UInt32,
    UInt32,
    UnsafeMutablePointer<UInt8>,
    CFIndex
) -> Void

private func xrealHIDReportBridge(
    context: UnsafeMutableRawPointer?,
    result: Int32,
    sender: UnsafeMutableRawPointer?,
    reportType: UInt32,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, reportLength > 0 else { return }
    let driver = Unmanaged<XRealUSBHIDDriver>.fromOpaque(context).takeUnretainedValue()
    driver.handleRawReport(bytes: report, length: Int(reportLength))
}

final class XRealUSBHIDDriver {
    var onAnglesUpdated: ((Double, Double, Double) -> Void)?
    var onStatusChanged: ((String, Bool) -> Void)?

    private var iokitHandle: UnsafeMutableRawPointer?
    private var hidManager: UnsafeMutableRawPointer?
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var pollTimer: Timer?
    private(set) var isStreamingIMU = false

    // Integrated 3-DoF attitude from XREAL's internal ICM-20602 / Bosch IMU
    private var lastTimestampNS: UInt64 = 0
    private var integratedYaw: Double = 0
    private var integratedPitch: Double = 0
    private var integratedRoll: Double = 0

    // Automatic stationary gyro bias learning (eliminates ~0.45°/s yaw drift)
    private var biasGx: Double = 0
    private var biasGy: Double = 0
    private var biasGz: Double = 0
    private var biasSamples: Int = 0
    private var packetCounter: Int = 0

    func start() {
        attemptUSBAttach()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, !self.isStreamingIMU else { return }
            self.attemptUSBAttach()
        }
    }

    func resetAttitude() {
        integratedYaw = 0
        integratedPitch = 0
        integratedRoll = 0
    }

    private func attemptUSBAttach() {
        if iokitHandle == nil {
            iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        }
        guard let handle = iokitHandle else {
            onStatusChanged?("IOKit unavailable on this iOS build", false)
            return
        }

        typealias CreateFn = @convention(c) (UnsafeRawPointer?, UInt32) -> UnsafeMutableRawPointer?
        typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary?) -> Void
        typealias ScheduleFn = @convention(c) (UnsafeMutableRawPointer, CFRunLoop, CFString) -> Void
        typealias OpenFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32
        typealias CopyDevicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFSet>?
        typealias DevOpenFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32
        typealias DevScheduleFn = @convention(c) (UnsafeMutableRawPointer, CFRunLoop, CFString) -> Void
        typealias DevSetReportFn = @convention(c) (UnsafeMutableRawPointer, UInt32, CFIndex, UnsafePointer<UInt8>, CFIndex) -> Int32
        typealias DevRegCallbackFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>, CFIndex, IOHIDReportCallbackFn, UnsafeMutableRawPointer?) -> Void

        guard let createSym = dlsym(handle, "IOHIDManagerCreate"),
              let matchSym = dlsym(handle, "IOHIDManagerSetDeviceMatching"),
              let schedSym = dlsym(handle, "IOHIDManagerScheduleWithRunLoop"),
              let openSym = dlsym(handle, "IOHIDManagerOpen"),
              let copySym = dlsym(handle, "IOHIDManagerCopyDevices"),
              let devOpenSym = dlsym(handle, "IOHIDDeviceOpen"),
              let devSchedSym = dlsym(handle, "IOHIDDeviceScheduleWithRunLoop"),
              let devSetReportSym = dlsym(handle, "IOHIDDeviceSetReport"),
              let devRegSym = dlsym(handle, "IOHIDDeviceRegisterInputReportCallback") else {
            onStatusChanged?("IOHIDManager symbols restricted by iOS", false)
            return
        }

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
        let schedule = unsafeBitCast(schedSym, to: ScheduleFn.self)
        let openMgr = unsafeBitCast(openSym, to: OpenFn.self)
        let copyDevices = unsafeBitCast(copySym, to: CopyDevicesFn.self)
        let devOpen = unsafeBitCast(devOpenSym, to: DevOpenFn.self)
        let devSchedule = unsafeBitCast(devSchedSym, to: DevScheduleFn.self)
        let devSetReport = unsafeBitCast(devSetReportSym, to: DevSetReportFn.self)
        let devRegCallback = unsafeBitCast(devRegSym, to: DevRegCallbackFn.self)

        if hidManager == nil {
            guard let mgr = create(nil, 0) else { return }
            let matching: [String: Any] = ["VendorID": 0x3318] // XREAL / Nreal USB Vendor ID
            setMatching(mgr, matching as CFDictionary)
            schedule(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            _ = openMgr(mgr, 0)
            hidManager = mgr
        }

        guard let mgr = hidManager,
              let unmanagedSet = copyDevices(mgr) else {
            onStatusChanged?("iOS USB Sandbox hiding VID 0x3318 (using Vision Head/AirPods)", false)
            return
        }

        let deviceSet = unmanagedSet.takeRetainedValue()
        let count = CFSetGetCount(deviceSet)
        guard count > 0 else {
            onStatusChanged?("iOS USB Sandbox blocked direct HID 0x3318 (using Vision Head/AirPods)", false)
            return
        }

        var rawPtrs = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(deviceSet, &rawPtrs)

        let startIMUPacket = Self.buildXRealIMUStartPacket()
        let mcuEnablePacket = Self.buildXRealMCUEnablePacket()
        let selfOpaque = Unmanaged.passUnretained(self).toOpaque()

        for ptr in rawPtrs {
            guard let raw = ptr else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            _ = devOpen(dev, 0)
            devSchedule(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
            buf.initialize(repeating: 0, count: 512)
            reportBuffers.append(buf)

            devRegCallback(dev, buf, 512, xrealHIDReportBridge, selfOpaque)

            // Send XREAL IMU start command (0xAA ... msgid 0x19, payload 0x01) as Output (1) and Feature (2) report
            startIMUPacket.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                _ = devSetReport(dev, 1, 0, base, p.count)
                _ = devSetReport(dev, 2, 0, base, p.count)
            }
            mcuEnablePacket.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                _ = devSetReport(dev, 1, 0, base, p.count)
            }
        }

        onStatusChanged?("XREAL USB HID (0x3318) opened (\(count) interfaces)", false)
    }

    fileprivate func handleRawReport(bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        // 1. Standard XREAL Air / Air 2 / Air 2 Pro 64-byte IMU packet: signature [0x01, 0x02]
        if length >= 42 && bytes[0] == 0x01 && bytes[1] == 0x02 {
            let ts = Self.readU64LE(bytes, 4)
            let angMult = Double(Self.readU16LE(bytes, 12))
            let angDiv = Double(Self.readU32LE(bytes, 14))
            let gxRaw = Double(Self.readI24LE(bytes, 18))
            let gyRaw = Double(Self.readI24LE(bytes, 21))
            let gzRaw = Double(Self.readI24LE(bytes, 24))

            let accMult = Double(Self.readU16LE(bytes, 27))
            let accDiv = Double(Self.readU32LE(bytes, 29))
            let axRaw = Double(Self.readI24LE(bytes, 33))
            let ayRaw = Double(Self.readI24LE(bytes, 36))
            let azRaw = Double(Self.readI24LE(bytes, 39))

            guard angDiv > 0, accDiv > 0 else { return }
            let hwGx = gxRaw * angMult / angDiv // deg/s
            let hwGy = gyRaw * angMult / angDiv // deg/s
            let hwGz = gzRaw * angMult / angDiv // deg/s

            let hwAx = axRaw * accMult / accDiv // g
            let hwAy = ayRaw * accMult / accDiv // g
            let hwAz = azRaw * accMult / accDiv // g

            integrateXRealIMU(timestampNS: ts, hwGx: hwGx, hwGy: hwGy, hwGz: hwGz, hwAx: hwAx, hwAy: hwAy, hwAz: hwAz)
            return
        }

        // 2. XREAL Ultra / Light 0x11 float32 IMU packet
        if length >= 33 && bytes[0] == 0x11 {
            let ts = Self.readU64LE(bytes, 1)
            let gxRad = Double(Self.readF32LE(bytes, 9))
            let gyRad = Double(Self.readF32LE(bytes, 13))
            let gzRad = Double(Self.readF32LE(bytes, 17))
            let axM = Double(Self.readF32LE(bytes, 21)) / 9.81
            let ayM = Double(Self.readF32LE(bytes, 25)) / 9.81
            let azM = Double(Self.readF32LE(bytes, 29)) / 9.81

            integrateXRealIMU(
                timestampNS: ts,
                hwGx: gxRad * 180.0 / .pi,
                hwGy: gyRad * 180.0 / .pi,
                hwGz: gzRad * 180.0 / .pi,
                hwAx: axM,
                hwAy: ayM,
                hwAz: azM
            )
        }
    }

    private func integrateXRealIMU(
        timestampNS: UInt64,
        hwGx: Double,
        hwGy: Double,
        hwGz: Double,
        hwAx: Double,
        hwAy: Double,
        hwAz: Double
    ) {
        let dt: Double
        if lastTimestampNS > 0 && timestampNS > lastTimestampNS {
            let rawDt = Double(timestampNS - lastTimestampNS) * 1e-9
            dt = (rawDt > 0 && rawDt < 0.1) ? rawDt : 0.001
        } else {
            dt = 0.001
        }
        lastTimestampNS = timestampNS

        // Learn stationary gyro bias when glasses are still (< 1.2 deg/s total angular velocity)
        let magGyro = sqrt(hwGx * hwGx + hwGy * hwGy + hwGz * hwGz)
        if magGyro < 1.2 && biasSamples < 600 {
            let n = Double(biasSamples)
            biasGx = (biasGx * n + hwGx) / (n + 1.0)
            biasGy = (biasGy * n + hwGy) / (n + 1.0)
            biasGz = (biasGz * n + hwGz) / (n + 1.0)
            biasSamples += 1
        }

        let gx = hwGx - biasGx
        let gy = hwGy - biasGy
        let gz = hwGz - biasGz

        // Measured XREAL Air / Air 2 canonical frame:
        // Level worn: gravity = +hwZ; chin down: gravity moves onto +hwY -> canonical = (-hwX, hwZ, hwY)
        let pitchRate = -gx
        let yawRate = -gz
        let rollRate = gy

        integratedYaw += yawRate * dt
        integratedPitch += pitchRate * dt
        integratedRoll += rollRate * dt

        // Complementary gravity fusion for pitch & roll stability
        let accMag = sqrt(hwAx * hwAx + hwAy * hwAy + hwAz * hwAz)
        if accMag > 0.7 && accMag < 1.35 {
            let accelPitch = atan2(-hwAy, hwAz) * 180.0 / .pi
            let accelRoll = atan2(-hwAx, sqrt(hwAy * hwAy + hwAz * hwAz)) * 180.0 / .pi
            integratedPitch = 0.985 * integratedPitch + 0.015 * accelPitch
            integratedRoll = 0.985 * integratedRoll + 0.015 * accelRoll
        }

        packetCounter += 1
        // Throttle UI updates from ~1000Hz IMU down to ~60Hz for SwiftUI
        if packetCounter % 15 == 0 {
            let y = integratedYaw
            let p = integratedPitch
            let r = integratedRoll
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isStreamingIMU {
                    self.isStreamingIMU = true
                    self.onStatusChanged?("XREAL Glasses Internal USB IMU (1000Hz)", true)
                }
                self.onAnglesUpdated?(y, p, r)
            }
        }
    }

    // MARK: - XREAL Packet Framing & Little-Endian Helpers

    /// Builds the 64-byte XREAL IMU start packet (`0xAA`, CRC32 over `[0x04, 0x00, 0x19, 0x01]`, length `4`, msgid `0x19`, data `0x01`).
    private static func buildXRealIMUStartPacket() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 64)
        let payload: [UInt8] = [0x04, 0x00, 0x19, 0x01]
        let crc = crc32IEEE(payload)
        packet[0] = 0xAA
        packet[1] = UInt8(crc & 0xFF)
        packet[2] = UInt8((crc >> 8) & 0xFF)
        packet[3] = UInt8((crc >> 16) & 0xFF)
        packet[4] = UInt8((crc >> 24) & 0xFF)
        packet[5] = 0x04
        packet[6] = 0x00
        packet[7] = 0x19
        packet[8] = 0x01
        return packet
    }

    private static func buildXRealMCUEnablePacket() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 64)
        var body = [UInt8](repeating: 0, count: 18)
        body[0] = 18 // length u16 LE
        body[1] = 0
        body[10] = 0x19 // msgid u16 LE
        body[11] = 0x00
        body[17] = 0x01
        let crc = crc32IEEE(body)
        packet[0] = 0xFD
        packet[1] = UInt8(crc & 0xFF)
        packet[2] = UInt8((crc >> 8) & 0xFF)
        packet[3] = UInt8((crc >> 16) & 0xFF)
        packet[4] = UInt8((crc >> 24) & 0xFF)
        for i in 0..<body.count {
            packet[5 + i] = body[i]
        }
        return packet
    }

    private static func crc32IEEE(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }

    private static func readU16LE(_ p: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(p[offset]) | (UInt16(p[offset + 1]) << 8)
    }

    private static func readU32LE(_ p: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(p[offset])
            | (UInt32(p[offset + 1]) << 8)
            | (UInt32(p[offset + 2]) << 16)
            | (UInt32(p[offset + 3]) << 24)
    }

    private static func readU64LE(_ p: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        let lo = UInt64(readU32LE(p, offset))
        let hi = UInt64(readU32LE(p, offset + 4))
        return lo | (hi << 32)
    }

    private static func readI24LE(_ p: UnsafePointer<UInt8>, _ offset: Int) -> Int32 {
        let b0 = Int32(p[offset])
        let b1 = Int32(p[offset + 1]) << 8
        let b2 = Int32(Int8(bitPattern: p[offset + 2])) << 16
        return b0 | b1 | b2
    }

    private static func readF32LE(_ p: UnsafePointer<UInt8>, _ offset: Int) -> Float {
        let bits = readU32LE(p, offset)
        return Float(bitPattern: bits)
    }
}

// MARK: - Sunglasses-Compatible Vision Front-Camera Head Pose Tracker

final class VisionHeadPoseTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onHeadPose: ((Double, Double, Double) -> Void)?
    private let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.jarvis.xreal.visionhead", qos: .userInteractive)
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async {
                self.configureSession()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        queue.async { [weak self] in
            self?.captureSession.stopRunning()
            self?.isRunning = false
        }
    }

    private func configureSession() {
        guard !isRunning else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }
        captureSession.commitConfiguration()
        captureSession.startRunning()
        isRunning = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        try? handler.perform([request])

        guard let face = request.results?.first else { return }
        let box = face.boundingBox

        // Combine Vision head yaw/pitch/roll with head position in frame so it tracks smoothly even through dark XREAL lenses!
        let visionYawDeg = (face.yaw?.doubleValue ?? 0) * 180.0 / .pi
        let visionPitchDeg = (face.pitch?.doubleValue ?? 0) * 180.0 / .pi
        let visionRollDeg = (face.roll?.doubleValue ?? 0) * 180.0 / .pi

        let posYawDeg = Double(box.midX - 0.5) * -55.0
        let posPitchDeg = Double(box.midY - 0.5) * 45.0

        let fusedYaw = visionYawDeg != 0 ? (visionYawDeg * 0.7 + posYawDeg * 0.3) : posYawDeg
        let fusedPitch = visionPitchDeg != 0 ? (visionPitchDeg * 0.65 + posPitchDeg * 0.35) : posPitchDeg

        onHeadPose?(fusedYaw, fusedPitch, visionRollDeg)
    }
}

// MARK: - XREAL Spatial 3-DoF Modes, Head Tracking Sources & Palettes

enum XRealSpatialAnchorMode: String, CaseIterable, Identifiable {
    case worldAnchored = "3D World-Anchored"
    case gazeSwitch = "Head-Turn Switcher"
    case smoothFollow = "Smooth Parallax"
    case headLocked = "0-DoF Visor Lock"

    var id: String { rawValue }
}

enum XRealHeadTrackingSource: String, CaseIterable, Identifiable {
    case xrealAuto = "XREAL Glasses + Head (No Phone Gyro)"
    case xrealUSBOnly = "XREAL USB-C IMU (0x3318 Only)"
    case airpods = "AirPods 3D Head IMU"
    case visionCamera = "Front Camera Head Tracker"
    case deviceIMU = "iPhone Gyro IMU (Manual)"

    var id: String { rawValue }
}

enum XRealGazeZone: String {
    case leftWing = "LEFT WING // SYSTEMS & DOCKER"
    case centerCore = "CENTER // J.A.R.V.I.S. CORE"
    case rightWing = "RIGHT WING // OPTICS & AUDIO"
    case overhead = "OVERHEAD // TACTICAL CANOPY"
    case commandDock = "LOWER // GAZE COMMAND DOCK"
}

enum XRealHUDMode: String, CaseIterable, Identifiable {
    case tactical = "Tactical HUD"
    case minimal = "Minimal Walk"
    case security = "Cam Overwatch"
    case music = "Arc Audio"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tactical: return "viewfinder.circle.fill"
        case .minimal: return "eyeglasses"
        case .security: return "video.badge.checkmark"
        case .music: return "waveform.circle.fill"
        }
    }
}

enum XRealHUDPalette: String, CaseIterable, Identifiable {
    case cyan = "Jarvis Cyan"
    case crimson = "Mark XLVI Crimson"
    case emerald = "Stealth Emerald"
    case amber = "Tactical Amber"

    var id: String { rawValue }

    var primary: Color {
        switch self {
        case .cyan: return Color(red: 0.0, green: 0.92, blue: 1.0)
        case .crimson: return Color(red: 1.0, green: 0.22, blue: 0.35)
        case .emerald: return Color(red: 0.15, green: 0.98, blue: 0.60)
        case .amber: return Color(red: 1.0, green: 0.76, blue: 0.12)
        }
    }
}

// MARK: - XREAL Display & 3-DoF Spatial Head Tracker Manager

@MainActor
final class XRealDisplayManager: ObservableObject {
    static let shared = XRealDisplayManager()

    @Published var isExternalConnected = false
    @Published var externalResolution = "1920×1080"
    @Published var mode: XRealHUDMode = .tactical
    @Published var spatialMode: XRealSpatialAnchorMode = .worldAnchored
    @Published var trackingSource: XRealHeadTrackingSource = .xrealAuto {
        didSet { reconfigureHeadTracking() }
    }
    @Published var palette: XRealHUDPalette = .cyan
    @Published var hudOpacity: Double = 0.94
    @Published var hudScale: Double = 0.94
    @Published var spatialSensitivity: Double = 16.0
    @Published var activeCameraIndex = 0
    @Published var cursorPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Calibrated Relative 3-DoF Head Angles (Degrees)
    @Published var headYaw: Double = 0
    @Published var headPitch: Double = 0
    @Published var headRoll: Double = 0
    @Published var compassHeading: Double = 0
    @Published var activeTrackerLabel: String = "Probing XREAL USB 0x3318…"
    @Published var usbHIDStatus: String = "Probing USB-C HID 0x3318…"
    @Published var activeGazeZone: XRealGazeZone = .centerCore
    @Published var liveTranscript: String = ""

    // Dwell-to-Trigger state when looking at the Lower Command Dock
    @Published var dwellTargetIndex: Int? = nil
    @Published var dwellProgress: Double = 0.0
    var onGazeCommandTriggered: ((String) -> Void)?

    private var rawYaw: Double = 0
    private var rawPitch: Double = 0
    private var rawRoll: Double = 0
    private var centerYawOffset: Double = 0
    private var centerPitchOffset: Double = 0
    private var centerRollOffset: Double = 0
    private var hasInitialCenter = false

    private var lastUSBIMUTimestamp: Date = .distantPast
    private var lastAirPodsTimestamp: Date = .distantPast
    private var lastVisionTimestamp: Date = .distantPast

    private var externalWindow: UIWindow?
    private let usbDriver = XRealUSBHIDDriver()
    private let visionTracker = VisionHeadPoseTracker()
    private let headphoneMotion = CMHeadphoneMotionManager()
    private let deviceMotion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []
    private var cameraTimer: Timer?
    private var dwellTimer: Timer?

    private init() {
        setupNotifications()
        startAllTrackers()
        startCameraRefreshTimer()
        startDwellTimer()
        checkScreens()
    }

    private func setupNotifications() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkScreens() }
        })
        observers.append(nc.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkScreens() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkScreens() }
        })
    }

    func checkScreens() {
        let screens = UIScreen.screens
        guard screens.count > 1, let extScreen = screens.dropFirst().first else {
            isExternalConnected = false
            externalWindow?.isHidden = true
            externalWindow = nil
            return
        }
        extScreen.overscanCompensation = .none
        let bounds = extScreen.bounds
        externalResolution = "\(Int(bounds.width))×\(Int(bounds.height))"
        isExternalConnected = true
        attachExternalHUD(to: extScreen)
    }

    private func attachExternalHUD(to screen: UIScreen) {
        let rootView = XRealOpticalHUDView()
            .environmentObject(self)
            .environmentObject(JarvisSettings.shared)
            .environmentObject(ChatStore.shared)
            .environmentObject(ARTelemetryStore.shared)

        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .black

        let window: UIWindow
        if let matchingScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.screen == screen }) {
            window = UIWindow(windowScene: matchingScene)
        } else {
            window = UIWindow(frame: screen.bounds)
            window.screen = screen
        }
        window.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        externalWindow = window
    }

    // MARK: - Head Tracking Pipeline (XREAL USB 0x3318 -> AirPods Head IMU -> Vision Head Pose)
    // NOTE: iPhone Gyro is NEVER used unless explicitly selected in the picker!

    private func startAllTrackers() {
        // 1. Direct XREAL USB-C HID IMU Driver (VID 0x3318, Interface 3)
        usbDriver.onStatusChanged = { [weak self] status, streaming in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.usbHIDStatus = status
                if streaming {
                    self.activeTrackerLabel = "XREAL USB-C IMU (1000Hz)"
                }
            }
        }
        usbDriver.onAnglesUpdated = { [weak self] yaw, pitch, roll in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastUSBIMUTimestamp = Date()
                guard self.trackingSource == .xrealAuto || self.trackingSource == .xrealUSBOnly else { return }
                self.activeTrackerLabel = "XREAL Glasses USB IMU"
                self.ingestHeadAngles(yaw: yaw, pitch: pitch, roll: roll)
            }
        }
        usbDriver.start()

        // 2. AirPods / Beats Headphone IMU (Direct head tracking on iOS)
        if headphoneMotion.isDeviceMotionAvailable {
            headphoneMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let motion else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastAirPodsTimestamp = Date()
                    let usbActive = Date().timeIntervalSince(self.lastUSBIMUTimestamp) < 0.5
                    guard self.trackingSource == .airpods || (self.trackingSource == .xrealAuto && !usbActive) else { return }
                    let yaw = -motion.attitude.yaw * 180.0 / .pi
                    let pitch = motion.attitude.pitch * 180.0 / .pi
                    let roll = motion.attitude.roll * 180.0 / .pi
                    self.activeTrackerLabel = "AirPods 3D Head IMU"
                    self.ingestHeadAngles(yaw: yaw, pitch: pitch, roll: roll)
                }
            }
        }

        // 3. Sunglasses-Compatible Front Camera Vision Head Tracker (works while wearing XREAL glasses!)
        visionTracker.onHeadPose = { [weak self] yaw, pitch, roll in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastVisionTimestamp = Date()
                let now = Date()
                let usbActive = now.timeIntervalSince(self.lastUSBIMUTimestamp) < 0.5
                let airpodsActive = now.timeIntervalSince(self.lastAirPodsTimestamp) < 0.5
                guard self.trackingSource == .visionCamera || (self.trackingSource == .xrealAuto && !usbActive && !airpodsActive) else { return }
                self.activeTrackerLabel = "Vision 3D Head Tracker"
                self.ingestHeadAngles(yaw: yaw, pitch: pitch, roll: roll)
            }
        }
        visionTracker.start()

        // 4. iPhone Gyro IMU (ONLY used if user explicitly picks `.deviceIMU` in the menu; NEVER in Auto!)
        if deviceMotion.isDeviceMotionAvailable {
            deviceMotion.deviceMotionUpdateInterval = 1.0 / 60.0
            deviceMotion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let rawCompass = data.attitude.yaw * 180.0 / .pi
                    self.compassHeading = rawCompass < 0 ? rawCompass + 360.0 : rawCompass

                    guard self.trackingSource == .deviceIMU else { return }
                    self.activeTrackerLabel = "iPhone Gyro IMU (Manual)"
                    let yaw = -data.attitude.yaw * 180.0 / .pi
                    let pitch = data.attitude.pitch * 180.0 / .pi
                    let roll = data.attitude.roll * 180.0 / .pi
                    self.ingestHeadAngles(yaw: yaw, pitch: pitch, roll: roll)
                }
            }
        }
    }

    private func reconfigureHeadTracking() {
        hasInitialCenter = false
        if trackingSource == .xrealAuto || trackingSource == .visionCamera {
            visionTracker.start()
        } else {
            visionTracker.stop()
        }
    }

    private func ingestHeadAngles(yaw: Double, pitch: Double, roll: Double) {
        rawYaw = yaw
        rawPitch = pitch
        rawRoll = roll

        if !hasInitialCenter {
            centerYawOffset = yaw
            centerPitchOffset = pitch
            centerRollOffset = roll
            hasInitialCenter = true
        }

        let targetYaw = Self.normalizeAngle(yaw - centerYawOffset)
        let targetPitch = max(-65, min(65, pitch - centerPitchOffset))
        let targetRoll = max(-45, min(45, Self.normalizeAngle(roll - centerRollOffset)))

        let alpha = 0.30
        headYaw = headYaw + alpha * (targetYaw - headYaw)
        headPitch = headPitch + alpha * (targetPitch - headPitch)
        headRoll = headRoll + alpha * (targetRoll - headRoll)

        if headPitch > 15 {
            activeGazeZone = .overhead
        } else if headPitch < -13 {
            activeGazeZone = .commandDock
        } else if headYaw < -14 {
            activeGazeZone = .leftWing
        } else if headYaw > 14 {
            activeGazeZone = .rightWing
        } else {
            activeGazeZone = .centerCore
        }
    }

    /// Re-centers the 3D HUD so the user's current head direction becomes (0° yaw, 0° pitch, 0° roll).
    func recenterHUD() {
        usbDriver.resetAttitude()
        centerYawOffset = rawYaw
        centerPitchOffset = rawPitch
        centerRollOffset = rawRoll
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            headYaw = 0
            headPitch = 0
            headRoll = 0
            cursorPosition = CGPoint(x: 0.5, y: 0.5)
        }
    }

    private static func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360.0)
        if a > 180.0 { a -= 360.0 }
        if a < -180.0 { a += 360.0 }
        return a
    }

    // MARK: - Gaze Dwell Selection Timer

    private func startDwellTimer() {
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeGazeZone == .commandDock else {
                    self.dwellTargetIndex = nil
                    self.dwellProgress = 0
                    return
                }
                let clamped = max(-28.0, min(28.0, self.headYaw))
                let normalized = (clamped + 28.0) / 56.0
                let idx = min(3, max(0, Int(normalized * 4.0)))
                if self.dwellTargetIndex == idx {
                    self.dwellProgress += 0.08 / 1.4
                    if self.dwellProgress >= 1.0 {
                        self.dwellProgress = 0
                        self.triggerDockItem(at: idx)
                    }
                } else {
                    self.dwellTargetIndex = idx
                    self.dwellProgress = 0
                }
            }
        }
    }

    private func triggerDockItem(at index: Int) {
        switch index {
        case 0:
            onGazeCommandTriggered?("Give me a concise tactical homelab and server status report.")
        case 1:
            cycleCamera()
        case 2:
            MusicPlayer.shared.togglePlayPause()
        case 3:
            recenterHUD()
        default:
            break
        }
    }

    private func startCameraRefreshTimer() {
        cameraTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                ARTelemetryStore.shared.snapshotBuster = Int(Date().timeIntervalSince1970)
            }
        }
    }

    func cycleCamera() {
        let count = max(1, ARTelemetryStore.shared.cameras.count)
        activeCameraIndex = (activeCameraIndex + 1) % count
    }
}

// MARK: - Pure-Black (#000000) 3-DoF Spatial Optical HUD Rendered on XREAL Glasses

struct XRealOpticalHUDView: View {
    @EnvironmentObject private var xreal: XRealDisplayManager
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var telemetry: ARTelemetryStore
    @ObservedObject private var music = MusicPlayer.shared

    private var glow: Color { xreal.palette.primary }

    private var spatialOffsetX: CGFloat {
        switch xreal.spatialMode {
        case .worldAnchored:
            return CGFloat(-xreal.headYaw * xreal.spatialSensitivity)
        case .smoothFollow:
            return CGFloat(-xreal.headYaw * (xreal.spatialSensitivity * 0.45))
        case .gazeSwitch, .headLocked:
            return 0
        }
    }

    private var spatialOffsetY: CGFloat {
        switch xreal.spatialMode {
        case .worldAnchored:
            return CGFloat(xreal.headPitch * (xreal.spatialSensitivity * 0.72))
        case .smoothFollow:
            return CGFloat(xreal.headPitch * (xreal.spatialSensitivity * 0.35))
        case .gazeSwitch, .headLocked:
            return 0
        }
    }

    private var horizonRollAngle: Double {
        xreal.spatialMode == .headLocked ? 0 : -xreal.headRoll * 0.55
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if xreal.spatialMode != .headLocked {
                    artificialHorizonOverlay(size: geo.size)
                }

                Group {
                    if xreal.spatialMode == .gazeSwitch {
                        gazeSwitchHUDLayout(size: geo.size)
                    } else {
                        switch xreal.mode {
                        case .tactical:
                            panoramicWorldHUDLayout(size: geo.size)
                        case .minimal:
                            minimalWalkLayout(size: geo.size)
                        case .security:
                            securityOverwatchLayout(size: geo.size)
                        case .music:
                            musicArcLayout(size: geo.size)
                        }
                    }
                }
                .offset(x: spatialOffsetX, y: spatialOffsetY)
                .rotation3DEffect(
                    .degrees(xreal.spatialMode == .headLocked ? 0 : xreal.headYaw * 0.22),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.45
                )
                .rotation3DEffect(
                    .degrees(xreal.spatialMode == .headLocked ? 0 : -xreal.headPitch * 0.18),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.45
                )
                .scaleEffect(xreal.hudScale)
                .opacity(xreal.hudOpacity)
                .animation(.interpolatingSpring(stiffness: 140, damping: 19), value: xreal.headYaw)
                .animation(.interpolatingSpring(stiffness: 140, damping: 19), value: xreal.headPitch)

                visorTopGazeIndicator
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 6)

                Circle()
                    .strokeBorder(glow, lineWidth: 2)
                    .background(Circle().fill(glow.opacity(0.25)))
                    .frame(width: 18, height: 18)
                    .position(
                        x: geo.size.width * xreal.cursorPosition.x,
                        y: geo.size.height * xreal.cursorPosition.y
                    )
                    .shadow(color: glow, radius: 6)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func artificialHorizonOverlay(size: CGSize) -> some View {
        ZStack {
            ForEach([-20, -10, 0, 10, 20], id: \.self) { rung in
                let yShift = CGFloat(Double(rung) - xreal.headPitch) * 6.5
                HStack(spacing: 50) {
                    Rectangle()
                        .fill(glow.opacity(rung == 0 ? 0.35 : 0.16))
                        .frame(width: rung == 0 ? 48 : 24, height: rung == 0 ? 1.5 : 1)
                    Text("\(rung > 0 ? "+" : "")\(rung)°")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(glow.opacity(0.35))
                    Rectangle()
                        .fill(glow.opacity(rung == 0 ? 0.35 : 0.16))
                        .frame(width: rung == 0 ? 48 : 24, height: rung == 0 ? 1.5 : 1)
                }
                .offset(y: yShift)
            }
        }
        .rotationEffect(.degrees(horizonRollAngle))
        .allowsHitTesting(false)
    }

    private var visorTopGazeIndicator: some View {
        HStack(spacing: 12) {
            Text(xreal.activeGazeZone.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
            Text(String(format: "YAW %+03.0f° · PTC %+02.0f° · RLL %+02.0f°", xreal.headYaw, xreal.headPitch, xreal.headRoll))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(glow.opacity(0.5), lineWidth: 1))
    }

    private func panoramicWorldHUDLayout(size: CGSize) -> some View {
        let wingWidth = max(310, size.width * 0.44)
        let centerWidth = max(360, size.width * 0.46)

        return VStack(spacing: 18) {
            overheadCanopyBar(size: size)
                .scaleEffect(xreal.activeGazeZone == .overhead ? 1.08 : 0.94)
                .opacity(xreal.activeGazeZone == .overhead ? 1.0 : 0.65)

            HStack(alignment: .center, spacing: 38) {
                leftSystemsWing(isFocused: xreal.activeGazeZone == .leftWing)
                    .frame(width: wingWidth)
                    .scaleEffect(xreal.activeGazeZone == .leftWing ? 1.10 : 0.92)
                    .opacity(xreal.activeGazeZone == .leftWing ? 1.0 : 0.62)
                    .rotation3DEffect(.degrees(16), axis: (x: 0, y: 1, z: 0), perspective: 0.5)

                VStack(spacing: 12) {
                    topCompassRibbon
                    centerArcReticle
                    bottomSubtitleBar
                }
                .frame(width: centerWidth)
                .scaleEffect(xreal.activeGazeZone == .centerCore ? 1.03 : 0.92)
                .opacity(xreal.activeGazeZone == .centerCore ? 1.0 : 0.68)

                rightOpticsWing(isFocused: xreal.activeGazeZone == .rightWing)
                    .frame(width: wingWidth)
                    .scaleEffect(xreal.activeGazeZone == .rightWing ? 1.10 : 0.92)
                    .opacity(xreal.activeGazeZone == .rightWing ? 1.0 : 0.62)
                    .rotation3DEffect(.degrees(-16), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            }

            lowerGazeCommandDock
                .scaleEffect(xreal.activeGazeZone == .commandDock ? 1.10 : 0.90)
                .opacity(xreal.activeGazeZone == .commandDock ? 1.0 : 0.55)
        }
    }

    private func gazeSwitchHUDLayout(size: CGSize) -> some View {
        VStack(spacing: 14) {
            topCompassRibbon
                .padding(.horizontal, 28)
                .padding(.top, 24)

            Spacer()

            Group {
                switch xreal.activeGazeZone {
                case .leftWing:
                    leftSystemsWing(isFocused: true)
                        .frame(maxWidth: min(680, size.width * 0.85))
                case .rightWing:
                    rightOpticsWing(isFocused: true)
                        .frame(maxWidth: min(680, size.width * 0.85))
                case .overhead:
                    overheadCanopyBar(size: size)
                        .frame(maxWidth: min(680, size.width * 0.85))
                case .commandDock:
                    lowerGazeCommandDock
                        .frame(maxWidth: min(720, size.width * 0.88))
                case .centerCore:
                    centerArcReticle
                        .frame(maxWidth: min(500, size.width * 0.72))
                }
            }
            .transition(.opacity.combined(with: .scale))

            Spacer()

            bottomSubtitleBar
                .padding(.horizontal, 36)
                .padding(.bottom, 14)
        }
    }

    private func leftSystemsWing(isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            hudWingBox(title: isFocused ? "◀ FOCUSED // TRUENAS & AI BRAIN" : "◀ LOOK LEFT // SYSTEMS") {
                VStack(alignment: .leading, spacing: 6) {
                    hudKeyValue("CONTAINERS", "\(telemetry.runningContainers)/\(telemetry.totalContainers) RUNNING")
                    hudKeyValue("AI COMPUTE", telemetry.desktopOllamaOnline ? "RTX 5070 DESKTOP" : "NAS CORE")
                    hudKeyValue("SECURITY MODE", telemetry.alertsEnabled ? "ARMED (AWAY)" : "HOME MUTE")
                    hudKeyValue("HEAD TRACKER", xreal.activeTrackerLabel.uppercased())
                    if isFocused && !telemetry.topContainers.isEmpty {
                        Divider().overlay(glow.opacity(0.4))
                        Text("LIVE DOCKER FLEET:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(glow)
                        ForEach(telemetry.topContainers.prefix(6)) { c in
                            HStack {
                                Circle()
                                    .fill(c.state.lowercased() == "running" ? Theme.good : Theme.danger)
                                    .frame(width: 6, height: 6)
                                Text(c.name.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text(c.state.uppercased())
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(glow.opacity(0.85))
                            }
                        }
                    }
                }
            }

            hudWingBox(title: "AUDIO // NAVIDROME DECK") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(music.current?.displayTitle ?? "NO TRACK ACTIVE")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(music.current?.artist ?? "SAY 'PLAY MUSIC'")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(glow.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
    }

    private func rightOpticsWing(isFocused: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            hudWingBox(title: isFocused ? "FOCUSED // LIVE FRIGATE OPTICS ▶" : "LOOK RIGHT // CAMERAS ▶") {
                let cams = telemetry.cameras
                let cam = cams.indices.contains(xreal.activeCameraIndex) ? cams[xreal.activeCameraIndex] : ARCameraInfo(id: "doorbell", name: "Front Doorbell")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(cam.name.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(glow)
                        Spacer()
                        Text(isFocused ? "HI-RES FEED" : "PIP FEED")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(glow.opacity(0.75))
                    }
                    if let url = telemetry.snapshotURL(for: cam.id) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable()
                                    .aspectRatio(16 / 9, contentMode: .fill)
                                    .frame(height: isFocused ? 165 : 115)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(glow.opacity(0.8), lineWidth: isFocused ? 2 : 1))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(glow.opacity(0.4), lineWidth: 1)
                                    .frame(height: isFocused ? 165 : 115)
                                    .overlay(
                                        Text("SYNCING CAMERA OPTICS…")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(glow.opacity(0.7))
                                    )
                            }
                        }
                    }
                    if isFocused && !telemetry.cameraEvents.isEmpty {
                        Divider().overlay(glow.opacity(0.4))
                        Text("RECENT AI DETECTIONS:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(glow)
                        ForEach(telemetry.cameraEvents.prefix(3)) { ev in
                            Text("• \(ev.camera.uppercased()): \(ev.label.uppercased()) (\(ev.score)%) · \(ev.formattedTime)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                    } else if let latest = telemetry.cameraEvents.first {
                        Text("LAST: \(latest.label.uppercased()) (\(latest.score)%) · \(latest.formattedTime)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func overheadCanopyBar(size: CGSize) -> some View {
        HStack(spacing: 24) {
            Label("OVERHEAD TELEMETRY CANOPY", systemImage: "safari.fill")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
            Text(String(format: "MAGNETIC HDG %03.0f°", xreal.compassHeading))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
            Text("OPTICS: \(xreal.externalResolution)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(glow)
            Text("TRACKER: \(xreal.activeTrackerLabel.uppercased())")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(glow.opacity(0.6), lineWidth: 1))
    }

    private var lowerGazeCommandDock: some View {
        let items: [(String, String)] = [
            ("STATUS REPORT", "cpu"),
            ("NEXT CAMERA", "video.fill"),
            (music.isPlaying ? "PAUSE AUDIO" : "PLAY AUDIO", music.isPlaying ? "pause.fill" : "play.fill"),
            ("RECENTER 0°", "scope")
        ]
        return VStack(spacing: 6) {
            Text("▼ LOWER GAZE COMMAND DOCK (LOOK DOWN & HOLD 1.4S TO TRIGGER HANDS-FREE) ▼")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)

            HStack(spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    let isDwelling = (xreal.activeGazeZone == .commandDock && xreal.dwellTargetIndex == idx)
                    HStack(spacing: 6) {
                        Image(systemName: item.1)
                            .font(.system(size: 11, weight: .bold))
                        Text(item.0)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(isDwelling ? .black : glow)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isDwelling ? glow.opacity(0.25) : Color.black.opacity(0.8))
                            if isDwelling {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(glow)
                                    .scaleEffect(x: max(0.05, xreal.dwellProgress), y: 1.0, anchor: .leading)
                            }
                        }
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(glow, lineWidth: isDwelling ? 2 : 1))
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(glow.opacity(0.55), lineWidth: 1))
    }

    private func minimalWalkLayout(size: CGSize) -> some View {
        VStack {
            HStack {
                Text(Date(), style: .time)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Spacer()
                Text(String(format: "HDG %03.0f° (YAW %+02.0f°)", xreal.compassHeading, xreal.headYaw))
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Spacer()
                if let song = music.current {
                    Label(song.displayTitle, systemImage: "music.note")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(glow)
                        .lineLimit(1)
                }
            }
            .padding(24)

            Spacer()

            if let lastTurn = chat.turns.last {
                Text(lastTurn.text)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(14)
                    .background(Color.black.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(glow.opacity(0.7), lineWidth: 1))
                    .padding(.horizontal, 60)
                    .padding(.bottom, 24)
            }
        }
    }

    private func securityOverwatchLayout(size: CGSize) -> some View {
        VStack(spacing: 16) {
            topCompassRibbon.padding(.horizontal, 28).padding(.top, 12)
            HStack(spacing: 14) {
                ForEach(telemetry.cameras) { cam in
                    hudWingBox(title: cam.name.uppercased()) {
                        if let url = telemetry.snapshotURL(for: cam.id) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable()
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(glow.opacity(0.4), lineWidth: 1)
                                        .frame(height: 150)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            bottomSubtitleBar.padding(.horizontal, 36).padding(.bottom, 14)
        }
    }

    private func musicArcLayout(size: CGSize) -> some View {
        VStack(spacing: 22) {
            Spacer()
            centerArcReticle
            if let song = music.current {
                Text(song.displayTitle.uppercased())
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(glow)
                Text(song.artist ?? "")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            bottomSubtitleBar.padding(.horizontal, 36).padding(.bottom, 14)
        }
    }

    private var topCompassRibbon: some View {
        HStack(spacing: 16) {
            Text("J.A.R.V.I.S. // 3-DOF SPATIAL OPTICS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)

            Spacer()

            HStack(spacing: 12) {
                Text(String(format: "HDG %03.0f°", xreal.compassHeading))
                Text(String(format: "YAW %+03.0f°", xreal.headYaw))
                Text(String(format: "PTC %+02.0f°", xreal.headPitch))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(glow)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(glow.opacity(0.6), lineWidth: 1))

            Spacer()

            Text(Date(), style: .time)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
        }
    }

    private var centerArcReticle: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(glow.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 155, height: 155)

                    Circle()
                        .trim(from: 0.05, to: 0.35)
                        .stroke(glow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 136, height: 136)
                        .rotationEffect(.degrees(t * 42 + xreal.headYaw * 1.5))

                    Circle()
                        .trim(from: 0.55, to: 0.85)
                        .stroke(glow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 112, height: 112)
                        .rotationEffect(.degrees(-t * 58 - xreal.headPitch * 1.5))

                    Circle()
                        .stroke(glow.opacity(0.45), lineWidth: 1)
                        .frame(width: 70, height: 70)

                    Image(systemName: chat.isSending ? "waveform" : "scope")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(glow)
                }
                .shadow(color: glow.opacity(0.6), radius: 10)

                if let lastAssistant = chat.turns.last(where: { $0.role == .assistant }) {
                    Text(lastAssistant.text)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .padding(12)
                        .background(Color.black.opacity(0.82))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(glow.opacity(0.65), lineWidth: 1)
                        )
                }
            }
        }
    }

    private var bottomSubtitleBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(chat.isSending ? Theme.warning : glow)
                .frame(width: 8, height: 8)
            Text(
                !xreal.liveTranscript.isEmpty
                    ? "VOICE INPUT: \"\(xreal.liveTranscript)\""
                    : (chat.isSending ? "JARVIS PROCESSING…" : "TURN HEAD LEFT/RIGHT/UP/DOWN TO PAN 3D HUD · DOUBLE-TAP PAD TO SPEAK")
            )
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(glow)
            .lineLimit(1)
            Spacer()
            Text(xreal.activeTrackerLabel.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(glow.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(glow.opacity(0.45), lineWidth: 1)
        )
    }

    private func hudWingBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
            Divider().overlay(glow.opacity(0.5))
            content()
        }
        .padding(10)
        .background(Color.black.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(glow.opacity(0.6), lineWidth: 1)
        )
    }

    private func hudKeyValue(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(glow)
        }
    }
}

// MARK: - iPhone Pocket Trackpad & 3-DoF Spatial Cockpit View

struct XRealCockpitView: View {
    var openSettings: () -> Void

    @EnvironmentObject private var xreal: XRealDisplayManager
    @EnvironmentObject private var settings: JarvisSettings
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var telemetry: ARTelemetryStore
    @ObservedObject private var music = MusicPlayer.shared
    @StateObject private var listener = SpeechRecognizer()

    @State private var showFullVisorOnPhone = false

    private let quickCommands: [(String, String)] = [
        ("System Status", "Give me a concise tactical homelab and server status report."),
        ("Doorbell Check", "Are there any recent person or parcel detections on the cameras?"),
        ("Morning Briefing", "Give me a quick J.A.R.V.I.S. daily briefing."),
        ("Shuffle Music", "shuffle my music")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // XREAL Connection & Live 3-DoF Head Tracker Status Banner
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: xreal.isExternalConnected ? "eyeglasses" : "gyroscope")
                                .font(.title3)
                                .foregroundStyle(xreal.palette.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(xreal.isExternalConnected
                                     ? "XREAL Connected (\(xreal.externalResolution))"
                                     : "XREAL 3-DoF Cockpit")
                                    .font(.subheadline.weight(.bold))
                                Text("Active Tracker: \(xreal.activeTrackerLabel)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(xreal.palette.primary)
                            }
                            Spacer()
                            Button {
                                xreal.recenterHUD()
                            } label: {
                                Label("Recenter", systemImage: "scope")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(xreal.palette.primary)
                        }

                        Text("USB Status: \(xreal.usbHIDStatus)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.secondaryText)

                        Text(String(format: "Zone: %@  |  Yaw %+03.0f° · Pitch %+02.0f° · Roll %+02.0f°",
                                    xreal.activeGazeZone.rawValue, xreal.headYaw, xreal.headPitch, xreal.headRoll))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white)
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

                    // Live Mini Preview / Full-Screen Visor Toggle
                    ZStack(alignment: .topTrailing) {
                        XRealOpticalHUDView()
                            .frame(height: showFullVisorOnPhone ? 290 : 175)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(xreal.palette.primary.opacity(0.6), lineWidth: 1.5)
                            )

                        Button {
                            withAnimation { showFullVisorOnPhone.toggle() }
                        } label: {
                            Image(systemName: showFullVisorOnPhone ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.bold))
                                .padding(8)
                                .background(.black.opacity(0.75), in: Circle())
                                .foregroundStyle(xreal.palette.primary)
                        }
                        .padding(8)
                    }

                    // 3-DoF Spatial Anchor Mode & Head Tracking Source Controls
                    VStack(spacing: 8) {
                        HStack {
                            Text("3D Spatial Mode")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Picker("3D Spatial Mode", selection: $xreal.spatialMode) {
                                ForEach(XRealSpatialAnchorMode.allCases) { sm in
                                    Text(sm.rawValue).tag(sm)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Gyro / Head Source")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Picker("Gyro / Head Source", selection: $xreal.trackingSource) {
                                ForEach(XRealHeadTrackingSource.allCases) { ts in
                                    Text(ts.rawValue).tag(ts)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack(spacing: 8) {
                            Text("Head Pan Speed")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                            Slider(value: $xreal.spatialSensitivity, in: 6.0...30.0)
                                .tint(xreal.palette.primary)
                        }
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

                    // Quick Tactical Voice/Command Chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickCommands, id: \.0) { label, prompt in
                                Button {
                                    sendToJarvis(prompt)
                                } label: {
                                    Text(label)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Theme.surfaceRaised, in: Capsule())
                                        .overlay(Capsule().stroke(xreal.palette.primary.opacity(0.45), lineWidth: 1))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }

                    // Eyes-Free Touch Trackpad & Double-Tap Voice Trigger
                    GeometryReader { geo in
                        ZStack {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(listener.isRecording ? Theme.danger : xreal.palette.primary.opacity(0.45), lineWidth: 1.5)
                                )

                            VStack(spacing: 6) {
                                Image(systemName: listener.isRecording ? "waveform.circle.fill" : "hand.point.up.braille.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(listener.isRecording ? Theme.danger : xreal.palette.primary)
                                Text(listener.isRecording ? "LISTENING… DOUBLE-TAP OR TAP BUTTON TO SEND" : "EYES-FREE AR TRACKPAD")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                Text("Slide thumb to aim reticle · Double-tap to speak · Triple-tap to recenter 0°")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let x = min(max(value.location.x / max(1, geo.size.width), 0.05), 0.95)
                                    let y = min(max(value.location.y / max(1, geo.size.height), 0.05), 0.95)
                                    xreal.cursorPosition = CGPoint(x: x, y: y)
                                }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 3).onEnded {
                                xreal.recenterHUD()
                            }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                toggleVoice()
                            }
                        )
                    }
                    .frame(minHeight: 105)

                    // Giant Eyes-Free Action Buttons
                    HStack(spacing: 10) {
                        Button {
                            toggleVoice()
                        } label: {
                            Label(listener.isRecording ? "Send Voice" : "Talk to Jarvis",
                                  systemImage: listener.isRecording ? "stop.circle.fill" : "mic.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(listener.isRecording ? Theme.danger : xreal.palette.primary)

                        Button {
                            xreal.cycleCamera()
                        } label: {
                            Label("Next Cam", systemImage: "video.fill")
                                .font(.caption.weight(.bold))
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(xreal.palette.primary)

                        Button {
                            music.togglePlayPause()
                        } label: {
                            Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                                .font(.headline)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(xreal.palette.primary)
                    }

                    // HUD Mode, Color Palette & Brightness Controls
                    HStack(spacing: 10) {
                        Picker("HUD Mode", selection: $xreal.mode) {
                            ForEach(XRealHUDMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("HUD Color", selection: $xreal.palette) {
                            ForEach(XRealHUDPalette.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                            Slider(value: $xreal.hudOpacity, in: 0.3...1.0)
                                .tint(xreal.palette.primary)
                        }
                    }
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("J.A.R.V.I.S. // 3-DOF XREAL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await telemetry.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onChange(of: listener.transcript) { newValue in
                xreal.liveTranscript = newValue
            }
            .task {
                xreal.onGazeCommandTriggered = { prompt in
                    sendToJarvis(prompt)
                }
                xreal.checkScreens()
                await telemetry.refreshAll()
            }
        }
    }

    private func toggleVoice() {
        if listener.isRecording {
            let spoken = listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            xreal.liveTranscript = ""
            guard !spoken.isEmpty else { return }
            sendToJarvis(spoken)
        } else {
            speaker.stop()
            if music.isPlaying { music.pause() }
            Task { await listener.start() }
        }
    }

    private func sendToJarvis(_ text: String) {
        if let cmd = MusicCommand.parse(text) {
            Task {
                if let reply = await MusicDJ.handle(cmd, account: settings.navidrome) {
                    chat.addExchange(user: text, reply: reply)
                    speaker.speak(reply, client: settings.client)
                }
            }
            return
        }
        chat.send(text, settings: settings) { reply, audioURL in
            speaker.speak(reply, audio: audioURL, client: settings.client)
        }
    }
}
