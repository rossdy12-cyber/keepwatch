import AVFoundation
import MediaPlayer
import UIKit

/// Plays Navidrome music in the background, with lock-screen and Control Center controls.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    @Published private(set) var queue: [SubsonicSong] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: UIImage?

    var client: NavidromeClient?

    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?

    var current: SubsonicSong? { queue.indices.contains(index) ? queue[index] : nil }
    var hasQueue: Bool { current != nil }

    private init() {
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { note in
            let finished = (note.object as? AVPlayerItem).map { ObjectIdentifier($0) }
            Task { @MainActor in MusicPlayer.shared.itemFinished(finished) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { observed, _ in
            let playing = observed.timeControlStatus != .paused
            Task { @MainActor in MusicPlayer.shared.playingChanged(playing) }
        }
        setUpRemoteCommands()
    }

    // MARK: Controls

    func play(_ songs: [SubsonicSong], startAt start: Int = 0) {
        guard !songs.isEmpty else { return }
        queue = songs
        index = max(0, min(start, songs.count - 1))
        loadCurrent()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard hasQueue else { return }
        if player.currentItem == nil { loadCurrent(); return }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func next() {
        guard index + 1 < queue.count else { stop(); return }
        index += 1
        loadCurrent()
    }

    func previous() {
        if player.currentTime().seconds > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            index -= 1
            loadCurrent()
        }
    }

    func stop() {
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        isPlaying = false
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// The microphone takes over the audio session; afterwards, carry on if music was playing.
    func restoreAfterListening(wasPlaying: Bool) {
        guard hasQueue else { return }
        activateSession()
        if wasPlaying { resume() }
    }

    // MARK: Internals

    /// False when iOS wouldn't let the music start (e.g. asked from Siri while Jarvis is in the background).
    @Published private(set) var lastStartAllowed = true

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            lastStartAllowed = true
        } catch {
            lastStartAllowed = false
        }
    }

    private func loadCurrent() {
        guard let song = current, let client, let url = client.streamURL(for: song) else { return }
        activateSession()
        let item = AVPlayerItem(url: url)
        let songId = song.id
        itemObservation = item.observe(\.status, options: [.new]) { observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor in
                // Skip a song this iPhone can't play rather than stopping the music.
                if MusicPlayer.shared.current?.id == songId { MusicPlayer.shared.next() }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlaying()
        loadArtwork(for: song, client: client)
        Task { await client.scrobble(songId, submission: false) }
    }

    private func itemFinished(_ itemId: ObjectIdentifier?) {
        guard let itemId, let item = player.currentItem, ObjectIdentifier(item) == itemId else { return }
        if let song = current, let client {
            Task { await client.scrobble(song.id, submission: true) }
        }
        next()
    }

    private func playingChanged(_ playing: Bool) {
        guard hasQueue, playing != isPlaying else { return }
        isPlaying = playing
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let song = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(song.duration ?? 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for song: SubsonicSong, client: NavidromeClient) {
        artwork = nil
        guard let url = client.coverURL(song.coverArt, size: 600) else { return }
        let songId = song.id
        Task {
            guard let result = try? await httpSession.data(from: url), let image = UIImage(data: result.0),
                  current?.id == songId else { return }
            artwork = image
            updateNowPlaying()
        }
    }

    /// Built outside the main actor: iOS asks for the artwork image on a background thread.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Task { @MainActor in MusicPlayer.shared.resume() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in MusicPlayer.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in MusicPlayer.shared.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in MusicPlayer.shared.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in MusicPlayer.shared.previous() }
            return .success
        }
    }
}
