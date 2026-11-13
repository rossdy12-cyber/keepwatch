import AVFoundation
import SwiftUI
import UIKit

// MARK: Download cache

/// Downloads media with the access token (Synapse requires it) and caches images and files.
actor MediaCache {
    static let shared = MediaCache()
    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private var files: [String: URL] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]


    private func data(api: MatrixAPI, url: URL) async -> Data? {
        let key = url.absoluteString
        if let task = inFlight[key] { return await task.value }
        let token = api.token
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let result = try? await MatrixAPI.session.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return result.0
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    func image(api: MatrixAPI, mxc: String, thumbnail: Int?) async -> UIImage? {
        let key = mxc + "|" + String(thumbnail ?? 0)
        if let hit = images[key] { return hit }
        guard let url = api.mediaURL(mxc, thumbnail: thumbnail) else { return nil }
        var data = await self.data(api: api, url: url)
        if data == nil, thumbnail != nil, let full = api.mediaURL(mxc) {
            data = await self.data(api: api, url: full)  // some media has no thumbnails (e.g. GIFs)
        }
        guard let data, let image = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) else { return nil }
        images[key] = image
        order.append(key)
        if order.count > 300 { images[order.removeFirst()] = nil }
        return image
    }

    /// Saves media to a file named like the original, for playing or sharing.
    func file(api: MatrixAPI, mxc: String, filename: String) async throws -> URL {
        if let hit = files[mxc], FileManager.default.fileExists(atPath: hit.path) { return hit }
        guard let url = api.mediaURL(mxc), let data = await self.data(api: api, url: url) else {
            throw MatrixError.server(code: "M_NOT_FOUND", message: "Couldn't download \(filename).", status: 404)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media/" + String(abs(mxc.hashValue)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let target = folder.appendingPathComponent(safe.isEmpty ? "file" : safe)
        try data.write(to: target)
        files[mxc] = target
        return target
    }
}

// MARK: Ogg Opus (WhatsApp and Discord voice notes)

enum OggOpus {
    enum DecodeError: Error { case notOpus, converter }

    static func isOgg(_ data: Data) -> Bool {
        data.count > 4 && data.prefix(4) == Data("OggS".utf8)
    }

    /// Splits an Ogg stream into its packets.
    static func packets(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var packets: [Data] = []
        var current = [UInt8]()
        var i = 0
        while i + 27 <= bytes.count {
            guard bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53 else { break }
            let segments = Int(bytes[i + 26])
            let table = i + 27
            guard table + segments <= bytes.count else { break }
            var offset = table + segments
            for s in 0..<segments {
                let length = Int(bytes[table + s])
                guard offset + length <= bytes.count else { return packets }
                current.append(contentsOf: bytes[offset..<(offset + length)])
                offset += length
                if length < 255 {
                    packets.append(Data(current))
                    current.removeAll(keepingCapacity: true)
                }
            }
            i = offset
        }
        return packets
    }

    /// Decodes Ogg Opus into a CAF file iOS can play.
    static func decode(_ data: Data) throws -> URL {
        let packets = packets(data)
        guard packets.count > 2, packets[0].starts(with: Data("OpusHead".utf8)), packets[0].count >= 19 else { throw DecodeError.notOpus }
        let channels = max(1, min(2, Int(packets[0][9])))
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(channels), interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw DecodeError.converter }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let file = try AVAudioFile(forWriting: url, settings: output.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let maxPacket = max(1, packets.map(\.count).max() ?? 1)
        var index = 2
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 48000) else { throw DecodeError.converter }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                guard index < packets.count else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let packet = packets[index]
                index += 1
                let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: maxPacket)
                packet.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { compressed.data.copyMemory(from: base, byteCount: packet.count) }
                }
                compressed.byteLength = UInt32(packet.count)
                compressed.packetCount = 1
                compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
                inputStatus.pointee = .haveData
                return compressed
            }
            if buffer.frameLength > 0 { try file.write(from: buffer) }
            if status == .error { throw error ?? DecodeError.converter }
            if status == .endOfStream || index >= packets.count && buffer.frameLength == 0 { break }
        }
        return url
    }
}

// MARK: Playback

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    @Published private(set) var playingID: String?
    @Published private(set) var loadingID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var prepared: [String: URL] = [:]

    func toggle(id: String, mxc: String, filename: String, api: MatrixAPI?) {
        if playingID == id, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            objectWillChange.send()
            return
        }
        stop()
        guard let api else { return }
        loadingID = id
        Task {
            defer { loadingID = nil }
            do {
                let url: URL
                if let ready = prepared[mxc] {
                    url = ready
                } else {
                    let downloaded = try await MediaCache.shared.file(api: api, mxc: mxc, filename: filename)
                    let data = try Data(contentsOf: downloaded)
                    url = OggOpus.isOgg(data) ? try await Task.detached { try OggOpus.decode(data) }.value : downloaded
                    prepared[mxc] = url
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.delegate = self
                newPlayer.play()
                player = newPlayer
                playingID = id
                duration = newPlayer.duration
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let player = self.player, player.duration > 0 else { return }
                        self.progress = player.currentTime / player.duration
                    }
                }
            } catch {
                playingID = nil
            }
        }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    func seek(_ fraction: Double) {
        guard let player else { return }
        player.currentTime = player.duration * fraction
        progress = fraction
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingID = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: Recording

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    func start() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return false }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let newRecorder = try AVAudioRecorder(url: target, settings: settings)
            newRecorder.isMeteringEnabled = true
            newRecorder.record()
            recorder = newRecorder
            url = target
            recording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.elapsed = recorder.currentTime
                    self.level = max(0, (recorder.averagePower(forChannel: 0) + 50) / 50)
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops and returns the recording (nil if cancelled or too short).
    func finish(cancel: Bool = false) -> (data: Data, duration: Double)? {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard !cancel, duration >= 0.7, let url, let data = try? Data(contentsOf: url) else { return nil }
        return (data, duration)
    }
}
