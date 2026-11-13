import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: Images and avatars

struct MXCImage: View {
    @EnvironmentObject private var matrix: MatrixStore
    let mxc: String?
    var thumbnail: Int? = 320
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Theme.surface
            }
        }
        .task(id: (mxc ?? "") + String(thumbnail ?? 0)) {
            guard let mxc, !mxc.isEmpty, let api = matrix.client else { return }
            image = await MediaCache.shared.image(api: api, mxc: mxc, thumbnail: thumbnail)
        }
    }
}

struct AvatarView: View {
    let mxc: String?
    let name: String
    var size: CGFloat = 44
    var square = false

    var body: some View {
        Group {
            if let mxc, !mxc.isEmpty {
                MXCImage(mxc: mxc, thumbnail: 96)
                    .frame(width: size, height: size)
                    .clipShape(square ? AnyShape(RoundedRectangle(cornerRadius: size * 0.3)) : AnyShape(Circle()))
                    .overlay {
                        if square {
                            RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(Theme.crimson.opacity(0.6), lineWidth: 1)
                        } else {
                            Circle().strokeBorder(Theme.crimson.opacity(0.6), lineWidth: 1)
                        }
                    }
            } else {
                Sigil(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Message content

extension String {
    /// Text with web links made tappable.
    var linkified: AttributedString {
        var attributed = AttributedString(self)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        let ns = self as NSString
        for match in detector.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: self),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Renders whatever a message carries: text, picture, video, voice note, file or location.
struct MessageContent: View {
    @EnvironmentObject private var matrix: MatrixStore
    let message: Message
    var mine = false
    var maxMediaWidth: CGFloat = 250
    var textColor: Color = Theme.bone
    @State private var showImage = false
    @State private var shareURL: URL?
    @State private var videoURL: URL?
    @State private var working = false

    var body: some View {
        switch message.kind {
        case .text, .emote, .notice:
            Text((message.kind == .emote ? "✱ " : "") + message.body).font(Theme.serif(16)).foregroundStyle(message.kind == .notice ? Theme.ash : textColor)
                .tint(Theme.ember)
                .textSelection(.enabled)
                .modifier(LinkText(text: message.body, color: message.kind == .notice ? Theme.ash : textColor))
        case .image, .sticker:
            if let media = message.media {
                MXCImage(mxc: media.mxc.isEmpty ? nil : media.mxc, thumbnail: 800, contentMode: .fill)
                    .frame(width: imageSize(media).width, height: imageSize(media).height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { showImage = true }
                    .fullScreenCover(isPresented: $showImage) { FullImage(mxc: media.mxc) }
                    .overlay { if message.pending { ProgressView().tint(Theme.bone) } }
            }
        case .video:
            if let media = message.media {
                ZStack {
                    if let thumb = media.thumbnail {
                        MXCImage(mxc: thumb, thumbnail: 800)
                    } else {
                        LinearGradient(colors: [Theme.raised, Theme.void], startPoint: .top, endPoint: .bottom)
                    }
                    if working || message.pending {
                        ProgressView().tint(Theme.bone)
                    } else {
                        Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.bone, Theme.crimson)
                    }
                }
                .frame(width: imageSize(media).width, height: imageSize(media).height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = media.duration {
                        Text(formatDuration(duration)).font(Theme.engraved(10)).foregroundStyle(Theme.bone)
                            .padding(4).background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                }
                .onTapGesture { Task { await open(media, asVideo: true) } }
                .fullScreenCover(item: Binding(get: { videoURL.map(IdentifiedURL.init) }, set: { videoURL = $0?.url })) { item in
                    VideoPlayer(player: AVPlayer(url: item.url))
                        .ignoresSafeArea()
                        .overlay(alignment: .topLeading) {
                            Button { videoURL = nil } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.bone, .black.opacity(0.6))
                            }
                            .padding()
                        }
                }
            }
        case .audio:
            if let media = message.media {
                VoicePlayer(id: message.id, media: media, mine: mine)
            }
        case .file:
            if let media = message.media {
                Button {
                    Task { await open(media, asVideo: false) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: working ? "hourglass" : "doc.fill").font(.system(size: 24)).foregroundStyle(Theme.ember)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(media.filename).font(Theme.serif(15, weight: .semibold)).foregroundStyle(textColor).lineLimit(2)
                            if let size = media.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(Theme.engraved(10)).foregroundStyle(Theme.ash)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .sheet(item: Binding(get: { shareURL.map(IdentifiedURL.init) }, set: { shareURL = $0?.url })) { item in
                    ActivitySheet(items: [item.url])
                }
            }
        case .location:
            Button {
                if let geo = message.geoURI, let url = mapsURL(geo) { UIApplication.shared.open(url) }
            } label: {
                Label(message.body.isEmpty ? "Location" : message.body, systemImage: "mappin.and.ellipse")
                    .font(Theme.serif(15)).foregroundStyle(textColor)
            }
            .buttonStyle(.plain)
        case .encrypted:
            Label("Encrypted message (can't be read here)", systemImage: "lock").font(Theme.serifItalic(14)).foregroundStyle(Theme.ash)
        case .redacted:
            Label("Message deleted", systemImage: "trash").font(Theme.serifItalic(14)).foregroundStyle(Theme.ash)
        case .unsupported(let type):
            Text("Unsupported message (\(type))").font(Theme.serifItalic(14)).foregroundStyle(Theme.ash)
        }
    }

    private func imageSize(_ media: MediaInfo) -> CGSize {
        let w = CGFloat(media.width ?? 4), h = CGFloat(media.height ?? 3)
        let width = min(maxMediaWidth, max(140, w))
        let height = min(320, max(100, width * h / max(1, w)))
        return CGSize(width: width, height: height)
    }

    private func mapsURL(_ geo: String) -> URL? {
        let coordinates = geo.replacingOccurrences(of: "geo:", with: "").split(separator: ";").first ?? ""
        return URL(string: "https://maps.apple.com/?ll=\(coordinates)&q=Location")
    }

    private func open(_ media: MediaInfo, asVideo: Bool) async {
        guard let api = matrix.client, !media.mxc.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let url = try await MediaCache.shared.file(api: api, mxc: media.mxc, filename: media.filename)
            if asVideo { videoURL = url } else { shareURL = url }
        } catch {
            matrix.errorMessage = error.localizedDescription
        }
    }
}

private struct LinkText: ViewModifier {
    let text: String
    let color: Color
    func body(content: Content) -> some View {
        if text.contains("http") || text.contains("www.") {
            Text(text.linkified).font(Theme.serif(16)).foregroundStyle(color).tint(Theme.ember).textSelection(.enabled)
        } else {
            content
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct VoicePlayer: View {
    @EnvironmentObject private var matrix: MatrixStore
    @ObservedObject private var playback = AudioPlayback.shared
    let id: String
    let media: MediaInfo
    var mine = false

    private var isCurrent: Bool { playback.playingID == id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle(id: id, mxc: media.mxc, filename: media.filename, api: matrix.client)
            } label: {
                ZStack {
                    Circle().fill(mine ? Theme.void.opacity(0.35) : Theme.crimson).frame(width: 36, height: 36)
                    if playback.loadingID == id {
                        ProgressView().tint(Theme.bone)
                    } else {
                        Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Theme.bone)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent && playback.isPlaying ? "Pause" : "Play voice note")
            VStack(alignment: .leading, spacing: 4) {
                Waveform(samples: media.waveform, progress: isCurrent ? playback.progress : 0)
                    .frame(width: 140, height: 22)
                Text(formatDuration(isCurrent ? playback.duration * playback.progress : (media.duration ?? 0)))
                    .font(Theme.engraved(10)).foregroundStyle(mine ? Theme.bone.opacity(0.8) : Theme.ash)
            }
        }
    }
}

struct Waveform: View {
    let samples: [Int]
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let count = 28
            let values: [CGFloat] = (0..<count).map { i in
                guard !samples.isEmpty else { return 0.25 + 0.55 * abs(sin(CGFloat(i) * 0.9)) }
                let index = min(samples.count - 1, i * samples.count / count)
                return max(0.12, min(1, CGFloat(samples[index]) / 1024))
            }
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(count) < progress ? Theme.ember : Theme.bone.opacity(0.45))
                        .frame(width: (geo.size.width - CGFloat(count - 1) * 2) / CGFloat(count), height: geo.size.height * values[i])
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct FullImage: View {
    @Environment(\.dismiss) private var dismiss
    let mxc: String
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MXCImage(mxc: mxc, thumbnail: nil, contentMode: .fit)
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation { scale = 1 } })
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.bone, .black.opacity(0.6))
            }
            .padding()
        }
        .onTapGesture(count: 1) {}
        .gesture(DragGesture().onEnded { if $0.translation.height > 120 { dismiss() } })
    }
}

/// The quoted message above a reply.
struct ReplyQuote: View {
    @EnvironmentObject private var matrix: MatrixStore
    let eventID: String
    let room: Room

    var body: some View {
        let original = matrix.message(eventID, in: room.id)
        HStack(spacing: 6) {
            Rectangle().fill(Theme.blood).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(original.map { matrix.displayName($0.sender, in: room) } ?? "Earlier message")
                    .font(Theme.engraved(10)).foregroundStyle(Theme.ember)
                Text(original.map(summary) ?? "…")
                    .font(Theme.serif(13)).foregroundStyle(Theme.ash).lineLimit(2)
            }
        }
        .padding(6)
        .background(Theme.void.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

func summary(_ message: Message) -> String {
    switch message.kind {
    case .image: return "📷 Photo"
    case .sticker: return "Sticker"
    case .video: return "🎞 Video"
    case .audio: return message.media?.isVoice == true ? "🎙 Voice note" : "🎵 Audio"
    case .file: return "📎 " + (message.media?.filename ?? "File")
    case .location: return "📍 Location"
    case .redacted: return "Message deleted"
    case .encrypted: return "Encrypted message"
    default: return message.body
    }
}

struct ReactionsRow: View {
    @EnvironmentObject private var matrix: MatrixStore
    let message: Message
    let roomID: String

    var body: some View {
        if !message.reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(message.reactions.sorted { $0.value.count > $1.value.count }, id: \.key) { key, users in
                    Button {
                        Task { await matrix.react(roomID, to: message, key: key) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(key).font(.system(size: 13))
                            if users.count > 1 { Text("\(users.count)").font(Theme.engraved(10)).foregroundStyle(Theme.bone) }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(users.contains(matrix.userID) ? Theme.crimson.opacity(0.6) : Theme.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(users.contains(matrix.userID) ? Theme.blood : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Composer

struct Composer: View {
    @EnvironmentObject private var matrix: MatrixStore
    let roomID: String
    @Binding var replyTo: Message?
    @Binding var editing: Message?
    var placeholder = "Whisper…"
    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @StateObject private var recorder = VoiceRecorder()
    @State private var lastTyping = Date.distantPast
    @State private var holding = false
    @State private var fieldID = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let target = replyTo ?? editing {
                HStack {
                    Rectangle().fill(Theme.blood).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(editing != nil ? "Editing" : "Replying to \(matrix.displayName(target.sender, in: matrix.rooms[roomID]))")
                            .font(Theme.engraved(10)).foregroundStyle(Theme.ember)
                        Text(summary(target)).font(Theme.serif(13)).foregroundStyle(Theme.ash).lineLimit(1)
                    }
                    Spacer()
                    Button { replyTo = nil; editing = nil; text = "" } label: { Image(systemName: "xmark").foregroundStyle(Theme.ash) }
                        .accessibilityLabel("Cancel")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.surface)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.recording {
                    Image(systemName: "record.circle").foregroundStyle(Theme.blood)
                        .scaleEffect(1 + CGFloat(recorder.level) * 0.3)
                    Text(formatDuration(recorder.elapsed)).font(Theme.engraved(14)).foregroundStyle(Theme.bone)
                    Text("Slide left to cancel").font(Theme.serifItalic(13)).foregroundStyle(Theme.ash)
                    Spacer()
                } else {
                    Menu {
                        Button { showPhotos = true } label: { Label("Photos and Videos", systemImage: "photo.on.rectangle") }
                        Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.bone, Theme.crimson)
                    }
                    .accessibilityLabel("Attach")
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.ash.opacity(0.6)), axis: .vertical)
                        .lineLimit(1...6)
                        .font(Theme.serif(16))
                        .foregroundStyle(Theme.bone)
                        .focused($focused)
                        .id(fieldID)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
                        .onChange(of: text) { _, value in
                            if !value.isEmpty, Date().timeIntervalSince(lastTyping) > 4 {
                                lastTyping = Date()
                                matrix.setTyping(roomID, true)
                            }
                        }
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(Theme.bone, Theme.blood)
                    }
                    .accessibilityLabel("Send")
                } else {
                    Image(systemName: recorder.recording ? "mic.fill" : "mic")
                        .font(.system(size: 22))
                        .foregroundStyle(recorder.recording ? Theme.blood : Theme.bone)
                        .frame(width: 36, height: 36)
                        .background(recorder.recording ? Theme.crimson.opacity(0.3) : Color.clear, in: Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !holding {
                                        holding = true
                                        Task { _ = await recorder.start() }
                                    }
                                    if value.translation.width < -90, recorder.recording { _ = recorder.finish(cancel: true) }
                                }
                                .onEnded { _ in
                                    holding = false
                                    guard recorder.recording, let clip = recorder.finish() else { return }
                                    let reply = replyTo
                                    replyTo = nil
                                    Task {
                                        await matrix.sendMedia(roomID, data: clip.data, filename: "Voice note.m4a", mimetype: "audio/mp4",
                                                               kind: .audio, duration: clip.duration, voice: true, replyTo: reply)
                                    }
                                }
                        )
                        .accessibilityLabel("Hold to record a voice note")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.void)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let type = UTType(filenameExtension: url.pathExtension)
                    await matrix.sendMedia(roomID, data: data, filename: url.lastPathComponent,
                                           mimetype: type?.preferredMIMEType ?? "application/octet-stream", kind: .file)
                }
            }
        }
        .onChange(of: editing) { _, message in
            if let message { text = message.body; focused = true }
        }
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        // A focused multi-line field can re-insert pending autocorrect text after
        // being cleared, so rebuild it and clear again on the next run loop.
        text = ""
        fieldID += 1
        DispatchQueue.main.async { text = ""; focused = true }
        matrix.setTyping(roomID, false)
        lastTyping = .distantPast
        let reply = replyTo, edit = editing
        replyTo = nil
        editing = nil
        Task {
            if let edit {
                await matrix.edit(roomID, edit, newText: value)
            } else {
                await matrix.sendText(roomID, value, replyTo: reply)
            }
        }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard var data = try? await item.loadTransferable(type: Data.self) else { continue }
            var type = item.supportedContentTypes.first ?? .data
            if type.conforms(to: .movie) {
                let ext = type.preferredFilenameExtension ?? "mov"
                await matrix.sendMedia(roomID, data: data, filename: "Video.\(ext)", mimetype: type.preferredMIMEType ?? "video/quicktime", kind: .video)
                continue
            }
            var width: Int?, height: Int?
            if let image = UIImage(data: data) {
                width = Int(image.size.width * image.scale)
                height = Int(image.size.height * image.scale)
                if !type.conforms(to: .jpeg) && !type.conforms(to: .png) && !type.conforms(to: .gif), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    data = jpeg
                    type = .jpeg
                }
            }
            let ext = type.preferredFilenameExtension ?? "jpg"
            await matrix.sendMedia(roomID, data: data, filename: "Photo.\(ext)", mimetype: type.preferredMIMEType ?? "image/jpeg",
                                   kind: .image, width: width, height: height)
        }
    }
}

// MARK: Sign in

struct MatrixSignIn: View {
    @EnvironmentObject private var matrix: MatrixStore
    let appName: String
    let tagline: String
    let deviceName: String
    @AppStorage("matrix.server") private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("✠").font(.system(size: 26)).foregroundStyle(Theme.blood).shadow(color: Theme.blood, radius: 12)
                        Text(appName)
                            .font(Theme.gothic(68))
                            .foregroundStyle(LinearGradient(colors: [Theme.bone, Theme.ember], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.crimson, radius: 18)
                        Text(tagline).font(Theme.engraved(12)).tracking(4).foregroundStyle(Theme.ash)
                        OrnamentDivider().padding(.top, 10)
                    }
                    .padding(.top, 30)
                    InscribedField(label: "Matrix server", text: $server, prompt: "http://100.x.y.z:8790", keyboard: .URL)
                    InscribedField(label: "Username", text: $user, prompt: "MATRIX_USER from the server's YAML", contentType: .username)
                    InscribedField(label: "Password", text: $password, prompt: "MATRIX_PASSWORD", secure: true, contentType: .password)
                    if let error {
                        Text(error).font(Theme.serif(15)).foregroundStyle(Theme.ember).multilineTextAlignment(.center)
                    }
                    Button {
                        Task {
                            working = true
                            defer { working = false }
                            do {
                                try await matrix.signIn(server: server, user: user, password: password, deviceName: deviceName)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack { if working { ProgressView().tint(Theme.bone) }; Text(working ? "Summoning…" : "Begin the \(appName)") }
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    .disabled(working || server.isEmpty || user.isEmpty || password.isEmpty)
                    Text("Set up the Matrix server on TrueNAS first (matrix-server/README.md), and keep Tailscale on.")
                        .font(Theme.serifItalic(13)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

func dayHeader(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(date: .long, time: .omitted)
}
