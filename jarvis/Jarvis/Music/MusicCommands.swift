import Foundation

/// A music request, recognised on the phone so it works instantly (and even when the Jarvis core is down).
enum MusicCommand: Equatable {
    enum Kind: Equatable { case any, artist, album, song, playlist, genre }

    case play(query: String, kind: Kind, artist: String?)
    case shuffleAll
    case pause, stop, resume, next, previous, nowPlaying

    /// Commands that start music shouldn't be answered out loud over the top of it.
    var startsMusic: Bool {
        switch self {
        case .play, .shuffleAll, .resume, .next, .previous: return true
        default: return false
        }
    }

    // MARK: Understanding what was said

    static func parse(_ raw: String) -> MusicCommand? {
        var text = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}'& ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let leading = ["hey jarvis ", "ok jarvis ", "okay jarvis ", "jarvis ", "please ", "can you ", "could you ",
                       "would you ", "will you ", "can i have ", "i want to hear ", "i'd like to hear ", "let's hear ",
                       "let's listen to ", "i want to listen to "]
        let trailing = [" please", " for me", " jarvis", " on navidrome", " from navidrome", " from my library",
                        " in my library", " now", " thanks"]
        var changed = true
        while changed {
            changed = false
            for prefix in leading where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)); changed = true
            }
            for suffix in trailing where text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count)); changed = true
            }
        }
        // "i want to hear X" / "let's listen to X" become plain requests.
        if raw.lowercased().range(of: "(want to hear|like to hear|let's hear|listen to)", options: .regularExpression) != nil,
           !text.hasPrefix("play ") {
            text = "play " + text
        }

        func isOneOf(_ options: [String]) -> Bool { options.contains(text) }

        if isOneOf(["pause", "pause music", "pause the music", "pause it", "pause this", "pause the song", "hold on", "be quiet", "quiet"]) {
            return .pause
        }
        if isOneOf(["stop", "stop music", "stop the music", "stop playing", "stop it", "stop the song", "turn the music off", "music off"]) {
            return .stop
        }
        if isOneOf(["resume", "resume music", "resume the music", "continue", "continue playing", "carry on", "unpause",
                    "keep playing", "play", "play music again", "start the music again"]) {
            return .resume
        }
        if isOneOf(["next", "skip", "next song", "next track", "skip song", "skip this", "skip this song", "skip track",
                    "skip it", "play the next song", "next one"]) {
            return .next
        }
        if isOneOf(["previous", "previous song", "previous track", "go back", "last song", "back", "play the last song",
                    "play that again", "play the previous song"]) {
            return .previous
        }
        if text.range(of: "^(what's|what is|what song is|who's|who is|whats) (playing|this|this song|singing|on)$", options: .regularExpression) != nil
            || isOneOf(["what am i listening to", "what song is this", "what's this song", "name this song", "what's this"]) {
            return .nowPlaying
        }
        if text.range(of: "^(shuffle|play)( (some|my|all|all my|all of my|any|me some|me))?( (music|songs|tunes|something|anything|everything|my music|my library|my songs|random music|random songs|some music))?$",
                      options: .regularExpression) != nil, text != "play" {
            return .shuffleAll
        }

        guard let prefix = ["play ", "put on ", "shuffle ", "queue up ", "queue "].first(where: { text.hasPrefix($0) }) else {
            return nil
        }
        var rest = String(text.dropFirst(prefix.count))
        var kind = Kind.any

        let starts: [(String, Kind)] = [
            ("me some ", .any), ("me ", .any), ("some more ", .any), ("some ", .any), ("a bit of ", .any), ("a little ", .any),
            ("the song ", .song), ("the track ", .song), ("song ", .song), ("track ", .song),
            ("the album ", .album), ("album ", .album), ("my playlist ", .playlist), ("the playlist ", .playlist),
            ("playlist ", .playlist), ("songs by ", .artist), ("music by ", .artist), ("something by ", .artist),
            ("anything by ", .artist), ("stuff by ", .artist), ("the artist ", .artist), ("artist ", .artist)
        ]
        var stripped = true
        while stripped {
            stripped = false
            for (start, startKind) in starts where rest.hasPrefix(start) {
                rest = String(rest.dropFirst(start.count))
                if startKind != .any { kind = startKind }
                stripped = true
            }
        }
        if kind == .any {
            if rest.hasSuffix(" playlist") { rest = String(rest.dropLast(9)); kind = .playlist }
            else if rest.hasSuffix(" album") { rest = String(rest.dropLast(6)); kind = .album }
            else if rest.hasSuffix(" songs") { rest = String(rest.dropLast(6)) }
            else if rest.hasSuffix(" music") { rest = String(rest.dropLast(6)); kind = .any }
        }
        if rest.hasPrefix("my ") && kind == .playlist { rest = String(rest.dropFirst(3)) }

        var artist: String?
        if kind != .artist && kind != .playlist, let range = rest.range(of: " by ", options: .backwards) {
            let after = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let before = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty && !before.isEmpty {
                artist = after
                rest = before
            }
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return .shuffleAll }
        return .play(query: rest, kind: kind, artist: artist)
    }
}

/// Finds the music for a request in Navidrome and starts it.
@MainActor
enum MusicDJ {
    /// The reply to show, or nil when this wasn't really a music request (it then goes to the Jarvis core).
    static func handle(_ command: MusicCommand, account: NavidromeAccount) async -> String? {
        let player = MusicPlayer.shared
        let client = NavidromeClient(account: account)
        player.client = client

        switch command {
        case .pause:
            guard player.hasQueue else { return "Nothing's playing." }
            player.pause()
            return "Paused."
        case .stop:
            guard player.hasQueue else { return "Nothing's playing." }
            player.stop()
            return "Music stopped."
        case .resume:
            if player.hasQueue {
                player.resume()
                return "Carrying on with \(songLabel(player.current))."
            }
            return await shuffleAll(client)
        case .next:
            guard player.hasQueue else { return "Nothing's playing." }
            player.next()
            return player.hasQueue ? "Next up: \(songLabel(player.current))." : "That was the last song."
        case .previous:
            guard player.hasQueue else { return "Nothing's playing." }
            player.previous()
            return "Playing \(songLabel(player.current))."
        case .nowPlaying:
            guard let song = player.current else { return "Nothing's playing at the moment." }
            var line = "This is \(songLabel(song))"
            if let album = song.album, !album.isEmpty { line += ", from \(album)" }
            return line + "."
        case .shuffleAll:
            return await shuffleAll(client)
        case .play(let query, let kind, let artist):
            guard account.isConfigured else { return MusicError.notSetUp.localizedDescription }
            do {
                return try await play(query: query, kind: kind, artist: artist, client: client)
            } catch {
                return describeError(error)
            }
        }
    }

    private static func shuffleAll(_ client: NavidromeClient) async -> String {
        guard client.account.isConfigured else { return MusicError.notSetUp.localizedDescription }
        do {
            let songs = try await client.randomSongs(size: 100)
            guard !songs.isEmpty else { return "Your Navidrome library looks empty." }
            MusicPlayer.shared.play(songs)
            return "Shuffling your music, starting with \(songLabel(songs.first))."
        } catch {
            return describeError(error)
        }
    }

    private static func play(query: String, kind: MusicCommand.Kind, artist: String?, client: NavidromeClient) async throws -> String? {
        let player = MusicPlayer.shared

        if kind == .playlist {
            let lists = try await client.playlists()
            guard let best = lists.max(by: { score($0.name, query) < score($1.name, query) }), score(best.name, query) >= 50 else {
                return "I couldn't find a playlist called \u{201c}\(query)\u{201d}."
            }
            let songs = try await client.playlist(best.id)
            guard !songs.isEmpty else { return "The \(best.name) playlist is empty." }
            player.play(songs)
            return "Playing your \(best.name) playlist."
        }

        var result = try await client.search(artist.map { query + " " + $0 } ?? query)
        if (result.song ?? []).isEmpty && (result.album ?? []).isEmpty && (result.artist ?? []).isEmpty && artist != nil {
            result = try await client.search(query)
        }
        let artistBonus: (String?) -> Int = { name in
            guard let artist, let name else { return 0 }
            return score(name, artist) >= 50 ? 30 : -20
        }

        let artists = (result.artist ?? []).map { ($0, score($0.name, query)) }
        let albums = (result.album ?? []).map { ($0, score($0.name ?? "", query) + artistBonus($0.artist)) }
        let songs = (result.song ?? []).map { ($0, score($0.title ?? "", query) + artistBonus($0.artist)) }
        let bestArtist = artists.max { $0.1 < $1.1 }
        let bestAlbum = albums.max { $0.1 < $1.1 }
        let bestSong = songs.max { $0.1 < $1.1 }

        // Which kind of thing to play. Ties go artist > album > song ("play Coldplay" means the artist).
        var choice = kind
        if choice == .any {
            let candidates: [(MusicCommand.Kind, Int)] = [
                (.artist, artist == nil ? (bestArtist?.1 ?? -1) : -1),
                (.album, (bestAlbum?.1 ?? -1) - 1),
                (.song, (bestSong?.1 ?? -1) - 2)
            ]
            let top = candidates.max { $0.1 < $1.1 }!
            if top.1 >= 48 {
                choice = top.0
            } else if let genre = try await matchingGenre(query, client: client) {
                return try await playGenre(genre, client: client)
            } else if let first = result.song?.first {
                // Navidrome found something, just not by name: go with its best guess.
                return try await playSong(first, client: client)
            } else if let first = result.album?.first {
                return try await playAlbum(first.id, client: client)
            } else {
                return nil // not music after all: let the Jarvis core answer
            }
        }

        switch choice {
        case .artist:
            guard let found = bestArtist?.0 ?? result.artist?.first else { return "I couldn't find an artist called \u{201c}\(query)\u{201d}." }
            return try await playArtist(found, client: client)
        case .album:
            guard let found = bestAlbum?.0 ?? result.album?.first else { return "I couldn't find an album called \u{201c}\(query)\u{201d}." }
            return try await playAlbum(found.id, client: client)
        case .song:
            guard let found = bestSong?.0 ?? result.song?.first else { return "I couldn't find a song called \u{201c}\(query)\u{201d}." }
            return try await playSong(found, client: client)
        case .genre:
            guard let genre = try await matchingGenre(query, client: client) else { return "I couldn't find any \(query) in your library." }
            return try await playGenre(genre, client: client)
        case .any, .playlist:
            return nil
        }
    }

    private static func playArtist(_ artist: SubsonicArtist, client: NavidromeClient) async throws -> String {
        var songs = try await client.topSongs(artist: artist.name)
        if songs.count < 10 {
            // No Last.fm top tracks: shuffle everything of theirs instead.
            let albums = try await client.artist(artist.id)?.album ?? []
            var all: [SubsonicSong] = []
            try await withThrowingTaskGroup(of: [SubsonicSong].self) { group in
                for album in albums.prefix(15) {
                    group.addTask { try await client.album(album.id)?.song ?? [] }
                }
                for try await albumSongs in group { all += albumSongs }
            }
            songs = all.shuffled()
        }
        guard !songs.isEmpty else { return "I found \(artist.name), but there are no songs to play." }
        MusicPlayer.shared.play(songs)
        return "Playing \(artist.name), starting with \(songs.first?.displayTitle ?? "a song")."
    }

    private static func playAlbum(_ id: String, client: NavidromeClient) async throws -> String {
        guard let album = try await client.album(id) else { return "I couldn't open that album." }
        let songs = (album.song ?? []).sorted { (($0.discNumber ?? 1), ($0.track ?? 0)) < (($1.discNumber ?? 1), ($1.track ?? 0)) }
        guard !songs.isEmpty else { return "That album has no songs." }
        MusicPlayer.shared.play(songs)
        var line = "Playing \(album.name ?? "the album")"
        if let artist = album.artist, !artist.isEmpty { line += " by \(artist)" }
        return line + "."
    }

    /// The song, then the rest of its album after it.
    private static func playSong(_ song: SubsonicSong, client: NavidromeClient) async throws -> String {
        var queue = [song]
        if let albumId = song.albumId, let album = try? await client.album(albumId) {
            let ordered = (album.song ?? []).sorted { (($0.discNumber ?? 1), ($0.track ?? 0)) < (($1.discNumber ?? 1), ($1.track ?? 0)) }
            if let position = ordered.firstIndex(where: { $0.id == song.id }) {
                queue = Array(ordered[position...])
            }
        }
        MusicPlayer.shared.play(queue)
        return "Playing \(songLabel(song))."
    }

    private static func matchingGenre(_ query: String, client: NavidromeClient) async throws -> String? {
        let genres = try await client.genres()
        let best = genres.max { score($0.value, query) < score($1.value, query) }
        guard let best, score(best.value, query) >= 70 else { return nil }
        return best.value
    }

    private static func playGenre(_ genre: String, client: NavidromeClient) async throws -> String {
        let songs = try await client.randomSongs(size: 80, genre: genre)
        guard !songs.isEmpty else { return "There's no \(genre) in your library." }
        MusicPlayer.shared.play(songs)
        return "Playing some \(genre), starting with \(songLabel(songs.first))."
    }

    // MARK: Helpers

    static func songLabel(_ song: SubsonicSong?) -> String {
        guard let song else { return "your music" }
        if let artist = song.artist, !artist.isEmpty { return "\(song.displayTitle) by \(artist)" }
        return song.displayTitle
    }

    private static func describeError(_ error: Error) -> String {
        if let music = error as? MusicError { return music.localizedDescription }
        if error is URLError { return "I couldn't reach Navidrome. " + describe(error) }
        return "Navidrome: " + error.localizedDescription
    }

    /// How well a name matches what was asked for, 0–100.
    static func score(_ name: String, _ query: String) -> Int {
        let a = normalise(name), b = normalise(query)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 100 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return 75 }
        if a.contains(b) || b.contains(a) { return 60 }
        let wordsA = Set(a.split(separator: " ")), wordsB = Set(b.split(separator: " "))
        let shared = wordsA.intersection(wordsB).count
        return shared * 45 / max(1, max(wordsA.count, wordsB.count))
    }

    private static func normalise(_ text: String) -> String {
        var value = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        value = value.replacingOccurrences(of: "&", with: " and ")
        value = value.replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "^the ", with: "", options: .regularExpression)
        return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
