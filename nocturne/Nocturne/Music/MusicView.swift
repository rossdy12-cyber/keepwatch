import SwiftUI
import AVFoundation
import CryptoKit
import UIKit

struct Album: Identifiable, Decodable { let id: String; let name: String; let artist: String?; let coverArt: String? }
struct Song: Identifiable, Decodable { let id: String; let title: String; let artist: String?; let album: String?; let coverArt: String?; let duration: Int? }

/// Minimal Subsonic client (Navidrome speaks Subsonic). Token auth: md5(password + salt).
struct Subsonic {
    let base: String
    let user: String
    let pass: String

    private func authQuery() -> String {
        let salt = String(UUID().uuidString.prefix(8))
        let token = Insecure.MD5.hash(data: Data((pass + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        return "u=\(user)&t=\(token)&s=\(salt)&v=1.16.1&c=Nocturne&f=json"
    }
    func url(_ path: String, _ extra: String = "") -> URL? {
        URL(string: "\(base)/rest/\(path)?\(authQuery())\(extra.isEmpty ? "" : "&" + extra)")
    }

    func ping() async -> Bool {
        guard let u = url("ping.view") else { return false }
        guard let (data, _) = try? await netSession.data(from: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["subsonic-response"] as? [String: Any] else { return false }
        return (r["status"] as? String) == "ok"
    }

    func albums() async -> [Album] {
        guard let u = url("getAlbumList2.view", "type=alphabeticalByName&size=100") else { return [] }
        guard let (data, _) = try? await netSession.data(from: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["subsonic-response"] as? [String: Any],
              let list = r["albumList2"] as? [String: Any],
              let arr = list["album"] as? [[String: Any]] else { return [] }
        return arr.compactMap { a in
            guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
            return Album(id: id, name: name, artist: a["artist"] as? String, coverArt: a["coverArt"] as? String)
        }
    }

    func songs(album id: String) async -> [Song] {
        guard let u = url("getAlbum.view", "id=\(id)") else { return [] }
        guard let (data, _) = try? await netSession.data(from: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["subsonic-response"] as? [String: Any],
              let alb = r["album"] as? [String: Any],
              let arr = alb["song"] as? [[String: Any]] else { return [] }
        return arr.compactMap { s in
            guard let id = s["id"] as? String, let title = s["title"] as? String else { return nil }
            return Song(id: id, title: title, artist: s["artist"] as? String, album: s["album"] as? String,
                        coverArt: s["coverArt"] as? String, duration: s["duration"] as? Int)
        }
    }
    func streamURL(_ id: String) -> URL? { url("stream.view", "id=\(id)") }
    func coverURL(_ id: String?) -> URL? { id.flatMap { url("getCoverArt.view", "id=\($0)&size=300") } }
}

@MainActor
final class Player: ObservableObject {
    @Published var current: Song?
    @Published var playing = false
    private var avp: AVPlayer?
    private var queue: [Song] = []
    private var index = 0
    var sub: Subsonic?

    func play(_ songs: [Song], at i: Int) {
        queue = songs; index = i; startCurrent()
    }
    private func startCurrent() {
        guard let sub, queue.indices.contains(index), let u = sub.streamURL(queue[index].id) else { return }
        current = queue[index]
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        avp = AVPlayer(url: u); avp?.play(); playing = true
    }
    func toggle() {
        guard let avp else { return }
        if playing { avp.pause() } else { avp.play() }
        playing.toggle()
    }
    func next() { if index + 1 < queue.count { index += 1; startCurrent() } }
    func prev() { if index > 0 { index -= 1; startCurrent() } }
}

struct MusicView: View {
    @EnvironmentObject var store: Store
    @StateObject private var player = Player()
    @State private var albums: [Album] = []
    @State private var openAlbum: Album?
    @State private var loading = true
    @State private var problem: String?
    private var theme: GothicTheme { store.theme }

    private var sub: Subsonic { Subsonic(base: ServerAddress.normalize(store.navURL), user: store.navUser, pass: store.navPass) }
    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 10) {
            GothicTitle(text: "Requiem", theme: theme, size: 26).padding(.top, 50)
            if store.navURL.isEmpty {
                Spacer()
                Text("Set your Navidrome server in the Altar to summon your library.")
                    .font(.system(.subheadline, design: .serif)).foregroundStyle(theme.mutedColor)
                    .multilineTextAlignment(.center).padding(40)
                Spacer()
            } else if loading {
                Spacer(); ProgressView().tint(theme.accentColor); Spacer()
            } else if let problem {
                Spacer(); Text(problem).foregroundStyle(theme.mutedColor).multilineTextAlignment(.center).padding(30)
                Button("Retry") { Task { await load() } }.foregroundStyle(theme.accentColor); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(albums) { a in
                            albumCard(a).onTapGesture { openAlbum = a }
                        }
                    }.padding(16)
                }
            }
            if player.current != nil { nowPlaying }
        }
        .task { player.sub = sub; if !store.navURL.isEmpty { await load() } }
        .sheet(item: $openAlbum) { a in AlbumSheet(album: a, sub: sub, theme: theme, player: player) }
    }

    private func load() async {
        loading = true; problem = nil
        if await sub.ping() == false { problem = "Couldn't reach Navidrome. Check the server, user and password."; loading = false; return }
        albums = await sub.albums(); loading = false
        if albums.isEmpty { problem = "No albums found." }
    }

    private func albumCard(_ a: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: sub.coverURL(a.coverArt)) { img in img.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { ZStack { theme.panelColor; Image(systemName: "music.note").foregroundStyle(theme.mutedColor) } }
                .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accentColor.opacity(0.3)))
            Text(a.name).font(.system(.subheadline, design: .serif)).foregroundStyle(theme.textColor).lineLimit(1)
            Text(a.artist ?? "").font(.caption).foregroundStyle(theme.mutedColor).lineLimit(1)
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform").foregroundStyle(theme.accentColor)
            VStack(alignment: .leading) {
                Text(player.current?.title ?? "").font(.system(.subheadline, design: .serif)).foregroundStyle(theme.textColor).lineLimit(1)
                Text(player.current?.artist ?? "").font(.caption).foregroundStyle(theme.mutedColor).lineLimit(1)
            }
            Spacer()
            Button { player.prev() } label: { Image(systemName: "backward.fill") }
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3) }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .foregroundStyle(theme.textColor)
        .padding(14)
        .background(theme.panelColor)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(theme.accentColor.opacity(0.3)), alignment: .top)
    }
}

struct AlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    let album: Album
    let sub: Subsonic
    let theme: GothicTheme
    @ObservedObject var player: Player
    @State private var songs: [Song] = []

    var body: some View {
        ZStack {
            GothicBackground(theme: theme)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    AsyncImage(url: sub.coverURL(album.coverArt)) { $0.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { theme.panelColor }
                        .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading) {
                        Text(album.name).font(.system(.title3, design: .serif)).foregroundStyle(theme.textColor)
                        Text(album.artist ?? "").font(.subheadline).foregroundStyle(theme.mutedColor)
                    }
                    Spacer()
                }.padding()
                List {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        Button { player.play(songs, at: i) } label: {
                            HStack {
                                Text("\(i + 1)").foregroundStyle(theme.mutedColor).frame(width: 24)
                                Text(s.title).foregroundStyle(theme.textColor)
                                Spacer()
                                if player.current?.id == s.id { Image(systemName: "waveform").foregroundStyle(theme.accentColor) }
                            }
                        }
                        .listRowBackground(theme.panelColor.opacity(0.5))
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { songs = await sub.songs(album: album.id) }
    }
}
