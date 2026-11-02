import CryptoKit
import Foundation

/// Your Navidrome sign-in, kept in the Keychain.
struct NavidromeAccount: Codable, Equatable {
    var address = "https://navidrome.nas-server.co.uk"
    var username = ""
    var password = ""
    /// nil = original files (lossless stays lossless); otherwise MP3 at this many kbps.
    var maxBitRate: Int? = 320

    var isConfigured: Bool {
        !ServerAddress.normalize(address).isEmpty && !username.isEmpty && !password.isEmpty
    }
}

/// Talks to Navidrome through the Subsonic API with token + salt auth: each request carries
/// `t` = md5(password + salt), never the password itself. (Same approach as the Hearth app.)
struct NavidromeClient {
    let account: NavidromeAccount
    private let base: String
    private let salt: String
    private let token: String

    init(account: NavidromeAccount) {
        self.account = account
        base = ServerAddress.normalize(account.address)
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        self.salt = salt
        token = Insecure.MD5.hash(data: Data((account.password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func url(_ endpoint: String, _ params: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: base + "/rest/" + endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "u", value: account.username), URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt), URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Jarvis"), URLQueryItem(name: "f", value: "json")
        ] + params
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private func call(_ endpoint: String, _ params: [URLQueryItem] = []) async throws -> SubsonicPayload {
        guard account.isConfigured else { throw MusicError.notSetUp }
        guard let url = url(endpoint, params) else { throw JarvisError.invalidURL }
        let (data, response) = try await httpSession.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MusicError.server("HTTP \(http.statusCode)")
        }
        guard let payload = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data).response else {
            throw MusicError.notNavidrome
        }
        guard payload.status == "ok" else {
            if payload.error?.code == 40 || payload.error?.code == 41 { throw MusicError.wrongPassword }
            throw MusicError.server(payload.error?.message ?? "Navidrome returned an error.")
        }
        return payload
    }

    func ping() async throws {
        _ = try await call("ping")
    }

    func search(_ query: String) async throws -> SubsonicSearchResult {
        try await call("search3", [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "artistCount", value: "10"),
            URLQueryItem(name: "albumCount", value: "20"), URLQueryItem(name: "songCount", value: "40")
        ]).searchResult3 ?? SubsonicSearchResult(artist: nil, album: nil, song: nil)
    }

    func album(_ id: String) async throws -> SubsonicAlbumDetail? {
        try await call("getAlbum", [URLQueryItem(name: "id", value: id)]).album
    }

    func artist(_ id: String) async throws -> SubsonicArtistDetail? {
        try await call("getArtist", [URLQueryItem(name: "id", value: id)]).artist
    }

    /// Navidrome fills this from Last.fm when that's set up; often empty otherwise.
    func topSongs(artist: String, count: Int = 40) async throws -> [SubsonicSong] {
        try await call("getTopSongs", [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "count", value: String(count))])
            .topSongs?.song ?? []
    }

    func randomSongs(size: Int = 60, genre: String? = nil) async throws -> [SubsonicSong] {
        var params = [URLQueryItem(name: "size", value: String(size))]
        if let genre { params.append(URLQueryItem(name: "genre", value: genre)) }
        return try await call("getRandomSongs", params).randomSongs?.song ?? []
    }

    func genres() async throws -> [SubsonicGenre] {
        try await call("getGenres").genres?.genre ?? []
    }

    func playlists() async throws -> [SubsonicPlaylist] {
        try await call("getPlaylists").playlists?.playlist ?? []
    }

    func playlist(_ id: String) async throws -> [SubsonicSong] {
        try await call("getPlaylist", [URLQueryItem(name: "id", value: id)]).playlist?.entry ?? []
    }

    func scrobble(_ songId: String, submission: Bool) async {
        _ = try? await call("scrobble", [URLQueryItem(name: "id", value: songId),
                                         URLQueryItem(name: "submission", value: submission ? "true" : "false")])
    }

    func coverURL(_ coverArt: String?, size: Int = 300) -> URL? {
        guard let coverArt else { return nil }
        return url("getCoverArt", [URLQueryItem(name: "id", value: coverArt), URLQueryItem(name: "size", value: String(size))])
    }

    private static let playableFormats: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff", "caf", "mp4", "m4b"]

    func streamURL(for song: SubsonicSong) -> URL? {
        let suffix = song.suffix?.lowercased() ?? ""
        let playable = suffix.isEmpty || Self.playableFormats.contains(suffix)
        var params = [URLQueryItem(name: "id", value: song.id)]
        if let kbps = account.maxBitRate ?? (playable ? nil : 320),
           !(suffix == "mp3" && (song.bitRate ?? 0) > 0 && (song.bitRate ?? 0) <= kbps) {
            params += [URLQueryItem(name: "format", value: "mp3"), URLQueryItem(name: "maxBitRate", value: String(kbps))]
        } else {
            params.append(URLQueryItem(name: "format", value: "raw"))
        }
        return url("stream", params)
    }
}

enum MusicError: LocalizedError {
    case notSetUp, wrongPassword, notNavidrome, server(String)

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Navidrome isn't set up yet. Add your Navidrome username and password in Settings → Music."
        case .wrongPassword: return "Navidrome didn't accept the username or password. Check them in Settings → Music."
        case .notNavidrome: return "Something answered at the Navidrome address, but it isn't Navidrome. Check it in Settings → Music."
        case .server(let message): return "Navidrome: \(message)"
        }
    }
}

// MARK: - Subsonic JSON

struct SubsonicEnvelope: Decodable {
    let response: SubsonicPayload
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicPayload: Decodable {
    let status: String
    let error: SubsonicErrorBody?
    let searchResult3: SubsonicSearchResult?
    let album: SubsonicAlbumDetail?
    let artist: SubsonicArtistDetail?
    let topSongs: SubsonicSongList?
    let randomSongs: SubsonicSongList?
    let genres: SubsonicGenres?
    let playlists: SubsonicPlaylists?
    let playlist: SubsonicPlaylistDetail?
}

struct SubsonicErrorBody: Decodable { let code: Int?; let message: String? }
struct SubsonicSongList: Decodable { let song: [SubsonicSong]? }
struct SubsonicGenres: Decodable { let genre: [SubsonicGenre]? }
struct SubsonicGenre: Decodable { let value: String; let songCount: Int? }
struct SubsonicPlaylists: Decodable { let playlist: [SubsonicPlaylist]? }
struct SubsonicPlaylist: Decodable { let id: String; let name: String; let songCount: Int? }
struct SubsonicPlaylistDetail: Decodable { let entry: [SubsonicSong]? }

struct SubsonicSearchResult: Decodable {
    let artist: [SubsonicArtist]?
    let album: [SubsonicAlbum]?
    let song: [SubsonicSong]?
}

struct SubsonicArtist: Decodable { let id: String; let name: String }

struct SubsonicAlbum: Decodable {
    let id: String
    let name: String?
    let artist: String?
}

struct SubsonicArtistDetail: Decodable {
    let id: String
    let name: String
    let album: [SubsonicAlbum]?
}

struct SubsonicAlbumDetail: Decodable {
    let id: String
    let name: String?
    let artist: String?
    let song: [SubsonicSong]?
}

struct SubsonicSong: Decodable, Identifiable, Equatable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let albumId: String?
    let coverArt: String?
    let duration: Int?
    let track: Int?
    let discNumber: Int?
    let suffix: String?
    let bitRate: Int?

    var displayTitle: String { title ?? "Unknown track" }
}
