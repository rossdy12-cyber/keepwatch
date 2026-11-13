import Foundation
import SwiftUI
import UIKit

// MARK: Models used by the UI

struct MediaInfo: Hashable, Codable {
    var mxc: String
    var mimetype: String?
    var size: Int?
    var width: Int?
    var height: Int?
    var duration: Double?        // seconds
    var thumbnail: String?
    var filename: String
    var isVoice = false
    var waveform: [Int] = []
}

enum MessageKind: Hashable, Codable {
    case text, notice, emote, image, video, audio, file, sticker, location, encrypted, redacted, unsupported(String)
}

struct Message: Identifiable, Hashable, Codable {
    var id: String                 // event ID, or a transaction ID while sending
    var eventID: String?
    var txnID: String?
    var sender: String
    var date: Date
    var kind: MessageKind
    var body: String
    var media: MediaInfo?
    var replyTo: String?
    var edited = false
    var reactions: [String: [String]] = [:]   // key -> senders
    var reactionEventIDs: [String: String] = [:] // "key|sender" -> reaction event ID
    var pending = false
    var failed = false
    var geoURI: String?
}

struct BridgeInfo: Hashable, Codable {
    var protocolID: String          // "whatsapp", "discord", ...
    var networkID: String?
    var networkName: String?
    var networkAvatar: String?
    var channelName: String?
}

struct Member: Hashable, Codable {
    var name: String?
    var avatar: String?
    var membership: String
}

struct Room: Identifiable, Hashable, Codable {
    let id: String
    var name: String?
    var topic: String?
    var avatar: String?
    var isSpace = false
    var isDirect = false
    var isInvite = false
    var bridge: BridgeInfo?
    var members: [String: Member] = [:]
    var heroes: [String] = []
    var joinedCount = 0
    var messages: [Message] = []
    var prevBatch: String?
    var reachedStart = false
    var unread = 0
    var highlights = 0
    var typing: [String] = []
    var readUpTo: [String: String] = [:]    // user -> event ID they've read up to
    var spaceChildren: [String] = []
    var lastActivity: Date = .distantPast
    var inviter: String?

    var lastMessage: Message? { messages.last { $0.kind != .redacted } }
}

// MARK: Store

@MainActor
class MatrixStore: ObservableObject {
    @Published private(set) var session: MatrixSession?
    @Published private(set) var rooms: [String: Room] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var initialSyncDone = false
    @Published var errorMessage: String?
    @Published private(set) var connectionProblem: String?

    let keychainService: String
    private var api: MatrixAPI?
    private var since: String?
    private var syncTask: Task<Void, Never>?
    private var directRooms: Set<String> = []
    private var pendingReactions: [String: [MatrixEvent]] = [:]   // target event -> reactions seen before the target
    private var pendingEdits: [String: MatrixEvent] = [:]

    init(keychainService: String) {
        self.keychainService = keychainService
        if let data = MatrixKeychain.read(service: keychainService, account: "session")?.data(using: .utf8),
           let saved = try? JSONDecoder().decode(MatrixSession.self, from: data),
           let base = URL(string: saved.homeserver) {
            session = saved
            api = MatrixAPI(base: base, token: saved.accessToken)
            loadCache()
        }
    }

    // MARK: Cache

    /// Rooms and the sync position, saved so a restart doesn't need a full (slow) sync again.
    private struct Cache: Codable {
        var userID: String
        var since: String
        var rooms: [String: Room]
        var direct: [String]
    }

    private var lastCacheSave = Date.distantPast

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("matrix-\(keychainService).json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.userID == session?.userID else { return }
        rooms = cache.rooms
        since = cache.since
        directRooms = Set(cache.direct)
        initialSyncDone = true
    }

    private func saveCache(force: Bool = false) {
        guard let since, let user = session?.userID, force || Date().timeIntervalSince(lastCacheSave) > 20 else { return }
        lastCacheSave = Date()
        var trimmed = rooms
        for id in trimmed.keys {
            if let count = trimmed[id]?.messages.count, count > 40 {
                trimmed[id]?.messages.removeFirst(count - 40)
                trimmed[id]?.reachedStart = false
            }
            trimmed[id]?.messages.removeAll { $0.pending || $0.failed }
            trimmed[id]?.typing = []
        }
        let cache = Cache(userID: user, since: since, rooms: trimmed, direct: Array(directRooms))
        let url = cacheURL
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    var client: MatrixAPI? { api }
    var userID: String { session?.userID ?? "" }
    var serverName: String { userID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "" }

    // MARK: Session

    func signIn(server: String, user: String, password: String, deviceName: String) async throws {
        guard let base = MatrixAPI.normalize(server) else { throw MatrixError.unreachable(server) }
        var username = user.trimmingCharacters(in: .whitespaces)
        if username.hasPrefix("@") { username = String(username.dropFirst().split(separator: ":").first ?? "") }
        let newSession = try await MatrixAPI(base: base, token: nil).login(user: username, password: password, deviceName: deviceName)
        if let data = try? JSONEncoder().encode(newSession), let text = String(data: data, encoding: .utf8) {
            MatrixKeychain.save(text, service: keychainService, account: "session")
        }
        session = newSession
        api = MatrixAPI(base: base, token: newSession.accessToken)
        rooms = [:]
        since = nil
        initialSyncDone = false
        clearCache()
        start()
    }

    func signOut() async {
        syncTask?.cancel()
        await api?.logout()
        MatrixKeychain.save("", service: keychainService, account: "session")
        clearCache()
        session = nil
        api = nil
        rooms = [:]
        since = nil
        initialSyncDone = false
    }

    // MARK: Sync loop

    func start() {
        guard syncTask == nil || syncTask!.isCancelled, api != nil else { return }
        syncTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let api = self.api else { return }
                do {
                    self.syncing = true
                    let response = try await api.sync(since: self.since, timeout: self.since == nil ? 0 : 30000)
                    self.apply(response)
                    self.since = response.next_batch
                    self.initialSyncDone = true
                    self.saveCache()
                    self.connectionProblem = nil
                    failures = 0
                } catch is CancellationError {
                    return
                } catch let error as MatrixError where error.isAuthFailure {
                    self.errorMessage = error.localizedDescription
                    await self.signOut()
                    return
                } catch {
                    failures += 1
                    self.connectionProblem = error.localizedDescription
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 2 * failures)) * 1_000_000_000)
                }
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Restart the long poll (e.g. when returning to the foreground).
    func resume() {
        stop()
        start()
    }

    // MARK: Applying sync results

    private func apply(_ response: SyncResponse) {
        for event in response.account_data?.events ?? [] where event.type == "m.direct" {
            var set = Set<String>()
            for (_, value) in event.content.object ?? [:] {
                for room in value.array ?? [] { if let id = room.string { set.insert(id) } }
            }
            directRooms = set
            for id in rooms.keys { rooms[id]?.isDirect = set.contains(id) || rooms[id]?.isDirect == true }
        }
        for (id, joined) in response.rooms?.join ?? [:] {
            var room = rooms[id] ?? Room(id: id)
            room.isInvite = false
            if room.messages.isEmpty || joined.timeline?.limited == true {
                if joined.timeline?.limited == true { room.messages.removeAll() }
                room.prevBatch = joined.timeline?.prev_batch
            }
            for event in joined.state?.events ?? [] { applyState(event, to: &room) }
            if let summary = joined.summary {
                if let heroes = summary.heroes { room.heroes = heroes }
                if let joinedCount = summary.joined { room.joinedCount = joinedCount }
            }
            for event in joined.timeline?.events ?? [] {
                if event.isState { applyState(event, to: &room) }
                applyTimeline(event, to: &room, prepend: false)
            }
            for event in joined.ephemeral?.events ?? [] { applyEphemeral(event, to: &room) }
            if let unread = joined.unread_notifications {
                room.unread = unread.notification_count ?? room.unread
                room.highlights = unread.highlight_count ?? room.highlights
            }
            if directRooms.contains(id) { room.isDirect = true }
            rooms[id] = room
        }
        for (id, invite) in response.rooms?.invite ?? [:] {
            var room = rooms[id] ?? Room(id: id)
            room.isInvite = true
            for event in invite.invite_state?.events ?? [] {
                applyState(event, to: &room)
                if event.type == "m.room.member", event.state_key == userID {
                    room.inviter = event.sender
                    if event.content["is_direct"]?.bool == true { room.isDirect = true }
                    room.lastActivity = max(room.lastActivity, event.date)
                }
            }
            rooms[id] = room
        }
        for (id, _) in response.rooms?.leave ?? [:] {
            rooms[id] = nil
        }
        didApplySync()
    }

    /// Subclasses can react to new data (for example, auto-accepting bridge invites).
    func didApplySync() {
        acceptBridgeInvites()
    }

    private var acceptedInvites: Set<String> = []

    /// Bridges invite you to a room for every chat or channel. Join those automatically
    /// (double puppeting usually does this, but not always).
    private func acceptBridgeInvites() {
        guard let api else { return }
        let server = ":" + serverName
        for room in rooms.values where room.isInvite && !acceptedInvites.contains(room.id) {
            guard let inviter = room.inviter, inviter.hasSuffix(server) else { continue }
            let local = inviter.dropFirst().split(separator: ":").first.map(String.init) ?? ""
            let fromBridge = ["whatsapp", "discord"].contains { local == $0 + "bot" || local.hasPrefix($0 + "_") }
            guard fromBridge else { continue }
            acceptedInvites.insert(room.id)
            let id = room.id
            Task { try? await api.join(room: id) }
        }
    }

    private func applyState(_ event: MatrixEvent, to room: inout Room) {
        let c = event.content
        switch event.type {
        case "m.room.name": room.name = c["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        case "m.room.topic": room.topic = c["topic"]?.string
        case "m.room.avatar": room.avatar = c["url"]?.string
        case "m.room.create":
            if c["type"]?.string == "m.space" { room.isSpace = true }
        case "m.room.member":
            guard let user = event.state_key else { break }
            room.members[user] = Member(name: c["displayname"]?.string, avatar: c["avatar_url"]?.string, membership: c["membership"]?.string ?? "leave")
            if user == userID, c["is_direct"]?.bool == true { room.isDirect = true }
        case "m.bridge", "uk.half-shot.bridge":
            guard let proto = c["protocol"]?["id"]?.string else { break }
            room.bridge = BridgeInfo(
                protocolID: proto,
                networkID: c["network"]?["id"]?.string,
                networkName: c["network"]?["displayname"]?.string,
                networkAvatar: c["network"]?["avatar_url"]?.string,
                channelName: c["channel"]?["displayname"]?.string
            )
        case "m.space.child":
            guard let child = event.state_key else { break }
            if c.object?.isEmpty ?? true {
                room.spaceChildren.removeAll { $0 == child }
            } else if !room.spaceChildren.contains(child) {
                room.spaceChildren.append(child)
            }
        default: break
        }
    }

    private func applyEphemeral(_ event: MatrixEvent, to room: inout Room) {
        switch event.type {
        case "m.typing":
            room.typing = (event.content["user_ids"]?.array ?? []).compactMap(\.string).filter { $0 != userID }
        case "m.receipt":
            for (eventID, value) in event.content.object ?? [:] {
                for (user, _) in value["m.read"]?.object ?? [:] {
                    room.readUpTo[user] = eventID
                }
            }
        default: break
        }
    }

    /// Turns a timeline event into a message, or applies it to an existing one (edits, reactions, redactions).
    private func applyTimeline(_ event: MatrixEvent, to room: inout Room, prepend: Bool) {
        let relates = event.content["m.relates_to"]
        switch event.type {
        case "m.reaction":
            guard let target = relates?["event_id"]?.string, let key = relates?["key"]?.string, let sender = event.sender else { return }
            if let index = room.messages.firstIndex(where: { $0.eventID == target }) {
                if !(room.messages[index].reactions[key]?.contains(sender) ?? false) {
                    room.messages[index].reactions[key, default: []].append(sender)
                }
                if let id = event.event_id { room.messages[index].reactionEventIDs["\(key)|\(sender)"] = id }
            } else {
                pendingReactions[target, default: []].append(event)
            }
            return
        case "m.room.redaction":
            let target = event.redacts ?? event.content["redacts"]?.string
            guard let target else { return }
            if let index = room.messages.firstIndex(where: { $0.eventID == target }) {
                room.messages[index].kind = .redacted
                room.messages[index].body = ""
                room.messages[index].media = nil
                room.messages[index].reactions = [:]
            } else {
                // A reaction being removed.
                for i in room.messages.indices {
                    if let entry = room.messages[i].reactionEventIDs.first(where: { $0.value == target }) {
                        let parts = entry.key.split(separator: "|", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            room.messages[i].reactions[parts[0]]?.removeAll { $0 == parts[1] }
                            if room.messages[i].reactions[parts[0]]?.isEmpty == true { room.messages[i].reactions[parts[0]] = nil }
                        }
                        room.messages[i].reactionEventIDs[entry.key] = nil
                    }
                }
            }
            return
        case "m.room.message", "m.sticker", "m.room.encrypted":
            break
        default:
            return
        }

        // Edits replace the content of the original message.
        if relates?["rel_type"]?.string == "m.replace", let target = relates?["event_id"]?.string {
            if let index = room.messages.firstIndex(where: { $0.eventID == target }), let newContent = event.content["m.new_content"] {
                var edited = Self.message(from: MatrixEvent(event_id: target, type: event.type, sender: room.messages[index].sender,
                                                            origin_server_ts: room.messages[index].date.timeIntervalSince1970 * 1000,
                                                            state_key: nil, content: newContent, unsigned: nil, redacts: nil))
                edited.id = room.messages[index].id
                edited.reactions = room.messages[index].reactions
                edited.reactionEventIDs = room.messages[index].reactionEventIDs
                edited.replyTo = room.messages[index].replyTo
                edited.edited = true
                room.messages[index] = edited
            } else {
                pendingEdits[target] = event
            }
            return
        }

        var message = Self.message(from: event)
        // Our own message coming back from the server: replace the local echo.
        if let txn = event.unsigned?["transaction_id"]?.string, let index = room.messages.firstIndex(where: { $0.txnID == txn }) {
            message.id = room.messages[index].id
            room.messages[index] = message
            return
        }
        if let id = event.event_id, room.messages.contains(where: { $0.eventID == id }) { return }
        if let id = event.event_id {
            for reaction in pendingReactions.removeValue(forKey: id) ?? [] {
                if let key = reaction.content["m.relates_to"]?["key"]?.string, let sender = reaction.sender {
                    message.reactions[key, default: []].append(sender)
                    if let rid = reaction.event_id { message.reactionEventIDs["\(key)|\(sender)"] = rid }
                }
            }
            if let edit = pendingEdits.removeValue(forKey: id), let newContent = edit.content["m.new_content"] {
                let replacement = Self.message(from: MatrixEvent(event_id: id, type: event.type, sender: event.sender, origin_server_ts: event.origin_server_ts,
                                                                 state_key: nil, content: newContent, unsigned: nil, redacts: nil))
                message.body = replacement.body
                message.kind = replacement.kind
                message.media = replacement.media
                message.edited = true
            }
        }
        if prepend {
            room.messages.insert(message, at: 0)
        } else {
            room.messages.append(message)
            room.lastActivity = max(room.lastActivity, message.date)
        }
    }

    static func message(from event: MatrixEvent) -> Message {
        let c = event.content
        var kind: MessageKind
        var media: MediaInfo?
        var body = c["body"]?.string ?? ""
        var geo: String?
        if event.type == "m.room.encrypted" {
            kind = .encrypted
            body = "Encrypted message"
        } else if event.type == "m.sticker" {
            kind = .sticker
            media = mediaInfo(c)
        } else if c.object?.isEmpty ?? true {
            kind = .redacted
        } else {
            switch c["msgtype"]?.string ?? "" {
            case "m.text": kind = .text
            case "m.notice": kind = .notice
            case "m.emote": kind = .emote
            case "m.image": kind = .image; media = mediaInfo(c)
            case "m.video": kind = .video; media = mediaInfo(c)
            case "m.audio": kind = .audio; media = mediaInfo(c)
            case "m.file": kind = .file; media = mediaInfo(c)
            case "m.location": kind = .location; geo = c["geo_uri"]?.string
            case let other: kind = body.isEmpty ? .unsupported(other) : .text
            }
        }
        let reply = c["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.string
        if reply != nil, kind == .text || kind == .notice {
            body = stripReplyFallback(body)
        }
        return Message(
            id: event.event_id ?? UUID().uuidString,
            eventID: event.event_id,
            txnID: event.unsigned?["transaction_id"]?.string,
            sender: event.sender ?? "",
            date: event.date,
            kind: kind,
            body: body,
            media: media,
            replyTo: reply,
            geoURI: geo
        )
    }

    private static func mediaInfo(_ c: JSON) -> MediaInfo? {
        guard let mxc = c["url"]?.string ?? c["file"]?["url"]?.string else { return nil }
        let info = c["info"]
        let audio = c["org.matrix.msc1767.audio"]
        return MediaInfo(
            mxc: mxc,
            mimetype: info?["mimetype"]?.string,
            size: info?["size"]?.int,
            width: info?["w"]?.int,
            height: info?["h"]?.int,
            duration: (info?["duration"]?.double ?? audio?["duration"]?.double).map { $0 / 1000 },
            thumbnail: info?["thumbnail_url"]?.string,
            filename: c["filename"]?.string ?? c["body"]?.string ?? "file",
            isVoice: c["org.matrix.msc3245.voice"] != nil,
            waveform: (audio?["waveform"]?.array ?? []).compactMap(\.int)
        )
    }

    /// Removes the "> <@user> quoted text" lines that clients put before a reply.
    static func stripReplyFallback(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard lines.first?.hasPrefix("> ") == true else { return body }
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") { index += 1 }
        while index < lines.count, lines[index].isEmpty { index += 1 }
        return lines[index...].joined(separator: "\n")
    }

    // MARK: Lookups

    func displayName(_ user: String, in room: Room?) -> String {
        if user == userID { return "You" }
        if let name = room?.members[user]?.name, !name.isEmpty { return name }
        for other in rooms.values {
            if let name = other.members[user]?.name, !name.isEmpty { return name }
        }
        let local = user.dropFirst().split(separator: ":").first.map(String.init) ?? user
        return local
    }

    func avatar(_ user: String, in room: Room?) -> String? {
        room?.members[user]?.avatar ?? rooms.values.lazy.compactMap { $0.members[user]?.avatar }.first
    }

    /// The best name for a room: its name, or for chats without one, the other people in it.
    func title(_ room: Room) -> String {
        if let name = room.name { return name }
        let others = (room.heroes.isEmpty ? Array(room.members.keys) : room.heroes).filter { $0 != userID }
        if others.isEmpty { return "Empty chat" }
        return others.prefix(3).map { displayName($0, in: room) }.joined(separator: ", ")
    }

    func roomAvatar(_ room: Room) -> String? {
        if let avatar = room.avatar { return avatar }
        if room.isDirect || room.joinedCount <= 2 {
            let other = (room.heroes.isEmpty ? Array(room.members.keys) : room.heroes).first { $0 != userID }
            return other.flatMap { avatar($0, in: room) }
        }
        return nil
    }

    func message(_ eventID: String, in roomID: String) -> Message? {
        rooms[roomID]?.messages.first { $0.eventID == eventID }
    }

    /// Whether everyone else in the room has read up to (or past) this message.
    func isRead(_ message: Message, in room: Room) -> Bool {
        guard let eventID = message.eventID, let position = room.messages.firstIndex(where: { $0.eventID == eventID }) else { return false }
        let others = room.readUpTo.filter { $0.key != userID && !$0.key.hasSuffix("bot:" + serverName) }
        return others.contains { _, readID in
            guard let readIndex = room.messages.firstIndex(where: { $0.eventID == readID }) else { return false }
            return readIndex >= position
        }
    }

    // MARK: Actions

    func loadOlder(_ roomID: String) async {
        guard let api, var room = rooms[roomID], !room.reachedStart else { return }
        do {
            let response = try await api.messages(room: roomID, from: room.prevBatch)
            room = rooms[roomID] ?? room
            for event in response.state ?? [] {
                if event.type == "m.room.member", let user = event.state_key, room.members[user] == nil {
                    applyState(event, to: &room)
                }
            }
            for event in response.chunk ?? [] {
                if event.isState { continue }
                applyTimeline(event, to: &room, prepend: true)
            }
            room.prevBatch = response.end
            if response.end == nil || (response.chunk ?? []).isEmpty { room.reachedStart = true }
            rooms[roomID] = room
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ roomID: String) {
        guard let api, let room = rooms[roomID], let last = room.messages.last(where: { $0.eventID != nil })?.eventID else { return }
        guard room.unread > 0 || room.readUpTo[userID] != last else { return }
        rooms[roomID]?.unread = 0
        rooms[roomID]?.highlights = 0
        rooms[roomID]?.readUpTo[userID] = last
        Task { try? await api.markRead(room: roomID, event: last) }
    }

    func setTyping(_ roomID: String, _ typing: Bool) {
        guard let api else { return }
        let user = userID
        Task { try? await api.typing(room: roomID, user: user, typing: typing) }
    }

    private func newTxn() -> String { "crypt\(Int(Date().timeIntervalSince1970 * 1000))\(Int.random(in: 1000...9999))" }

    /// Sends any message content with a local echo.
    func send(_ roomID: String, type: String = "m.room.message", content: [String: Any], preview: Message? = nil) async {
        guard let api else { return }
        let txn = newTxn()
        if rooms[roomID] == nil { rooms[roomID] = Room(id: roomID) }
        if var echo = preview {
            echo.id = txn
            echo.txnID = txn
            echo.pending = true
            echo.sender = userID
            echo.date = Date()
            rooms[roomID]?.messages.append(echo)
            rooms[roomID]?.lastActivity = Date()
        }
        do {
            let eventID = try await api.send(room: roomID, type: type, content: content, txn: txn)
            if let index = rooms[roomID]?.messages.firstIndex(where: { $0.txnID == txn }) {
                rooms[roomID]?.messages[index].eventID = rooms[roomID]?.messages[index].eventID ?? eventID
                rooms[roomID]?.messages[index].pending = false
            }
        } catch {
            if let index = rooms[roomID]?.messages.firstIndex(where: { $0.txnID == txn }) {
                rooms[roomID]?.messages[index].failed = true
                rooms[roomID]?.messages[index].pending = false
            }
            errorMessage = error.localizedDescription
        }
    }

    func sendText(_ roomID: String, _ text: String, replyTo: Message? = nil) async {
        var content: [String: Any] = ["msgtype": "m.text", "body": text]
        if let replyTo, let eventID = replyTo.eventID {
            content["m.relates_to"] = ["m.in_reply_to": ["event_id": eventID]]
        }
        let preview = Message(id: "", sender: userID, date: Date(), kind: .text, body: text, replyTo: replyTo?.eventID)
        await send(roomID, content: content, preview: preview)
    }

    func edit(_ roomID: String, _ message: Message, newText: String) async {
        guard let eventID = message.eventID else { return }
        let content: [String: Any] = [
            "msgtype": "m.text",
            "body": "* " + newText,
            "m.new_content": ["msgtype": "m.text", "body": newText],
            "m.relates_to": ["rel_type": "m.replace", "event_id": eventID]
        ]
        if let index = rooms[roomID]?.messages.firstIndex(where: { $0.eventID == eventID }) {
            rooms[roomID]?.messages[index].body = newText
            rooms[roomID]?.messages[index].edited = true
        }
        await send(roomID, content: content)
    }

    func react(_ roomID: String, to message: Message, key: String) async {
        guard let eventID = message.eventID else { return }
        // Tapping your own reaction again removes it.
        if let existing = message.reactionEventIDs["\(key)|\(userID)"] {
            await redact(roomID, eventID: existing)
            return
        }
        if let index = rooms[roomID]?.messages.firstIndex(where: { $0.eventID == eventID }),
           !(rooms[roomID]?.messages[index].reactions[key]?.contains(userID) ?? false) {
            rooms[roomID]?.messages[index].reactions[key, default: []].append(userID)
        }
        await send(roomID, type: "m.reaction", content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": eventID, "key": key]])
    }

    func redact(_ roomID: String, eventID: String) async {
        guard let api else { return }
        do {
            try await api.redact(room: roomID, event: eventID, txn: newTxn())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ roomID: String, _ message: Message) async {
        if let eventID = message.eventID {
            if let index = rooms[roomID]?.messages.firstIndex(where: { $0.eventID == eventID }) {
                rooms[roomID]?.messages[index].kind = .redacted
                rooms[roomID]?.messages[index].body = ""
            }
            await redact(roomID, eventID: eventID)
        } else {
            rooms[roomID]?.messages.removeAll { $0.id == message.id }
        }
    }

    /// Uploads a file and sends it as an image, video, audio or file message.
    func sendMedia(_ roomID: String, data: Data, filename: String, mimetype: String, kind: MessageKind,
                   width: Int? = nil, height: Int? = nil, duration: Double? = nil, voice: Bool = false, replyTo: Message? = nil) async {
        guard let api else { return }
        let txn = newTxn()
        var echo = Message(id: txn, txnID: txn, sender: userID, date: Date(), kind: kind, body: filename,
                           media: MediaInfo(mxc: "", mimetype: mimetype, size: data.count, width: width, height: height, duration: duration, filename: filename, isVoice: voice))
        echo.pending = true
        rooms[roomID]?.messages.append(echo)
        do {
            let mxc = try await api.upload(data, filename: filename, mimetype: mimetype)
            var info: [String: Any] = ["mimetype": mimetype, "size": data.count]
            if let width { info["w"] = width }
            if let height { info["h"] = height }
            if let duration { info["duration"] = Int(duration * 1000) }
            let msgtype: String
            switch kind {
            case .image: msgtype = "m.image"
            case .video: msgtype = "m.video"
            case .audio: msgtype = "m.audio"
            default: msgtype = "m.file"
            }
            var content: [String: Any] = ["msgtype": msgtype, "body": filename, "filename": filename, "url": mxc, "info": info]
            if voice {
                content["org.matrix.msc3245.voice"] = [String: Any]()
                content["org.matrix.msc1767.audio"] = ["duration": Int((duration ?? 0) * 1000), "waveform": [Int]()]
            }
            if let replyTo, let eventID = replyTo.eventID {
                content["m.relates_to"] = ["m.in_reply_to": ["event_id": eventID]]
            }
            if let index = rooms[roomID]?.messages.firstIndex(where: { $0.txnID == txn }) {
                rooms[roomID]?.messages[index].media?.mxc = mxc
            }
            let eventID = try await api.send(room: roomID, type: "m.room.message", content: content, txn: txn)
            if let index = rooms[roomID]?.messages.firstIndex(where: { $0.txnID == txn }) {
                rooms[roomID]?.messages[index].eventID = rooms[roomID]?.messages[index].eventID ?? eventID
                rooms[roomID]?.messages[index].pending = false
            }
        } catch {
            if let index = rooms[roomID]?.messages.firstIndex(where: { $0.txnID == txn }) {
                rooms[roomID]?.messages[index].failed = true
                rooms[roomID]?.messages[index].pending = false
            }
            errorMessage = error.localizedDescription
        }
    }

    func acceptInvite(_ roomID: String) async {
        guard let api else { return }
        do {
            try await api.join(room: roomID)
            rooms[roomID]?.isInvite = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func leave(_ roomID: String) async {
        guard let api else { return }
        do {
            try await api.leave(room: roomID)
            rooms[roomID] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Bridge bots

    func botID(_ bridge: String) -> String { "@\(bridge)bot:\(serverName)" }

    /// The management room with a bridge bot, created if needed.
    func managementRoom(for bridge: String) async throws -> String {
        let bot = botID(bridge)
        let key = "matrix.management.\(bridge)"
        // Until the first sync finishes we don't know which rooms exist; don't create duplicates.
        for _ in 0..<360 where !initialSyncDone {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard initialSyncDone else {
            throw MatrixError.server(code: "M_LOADING", message: "Still loading your chats from the server. Try again in a minute.", status: 0)
        }
        // Only plain chats with just you and the bot (bridges also create spaces with the bot in them).
        let candidates = rooms.values.filter {
            !$0.isInvite && !$0.isSpace && $0.bridge == nil && $0.members[bot]?.membership == "join" && $0.joinedCount <= 2
        }
        if let saved = UserDefaults.standard.string(forKey: key), candidates.contains(where: { $0.id == saved }) {
            return saved
        }
        // Prefer the room the bot has called its management room.
        let marked = candidates.first { room in
            room.messages.contains { $0.sender == bot && $0.body.lowercased().contains("management") }
        }
        if let chosen = marked ?? candidates.first(where: { $0.messages.contains { $0.sender == bot } }) {
            UserDefaults.standard.set(chosen.id, forKey: key)
            return chosen.id
        }
        guard let api else { throw MatrixError.notSignedIn }
        let id = try await api.createDirect(with: bot)
        UserDefaults.standard.set(id, forKey: key)
        // Wait for the bot to join.
        for _ in 0..<20 {
            if rooms[id]?.members[bot]?.membership == "join" { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return id
    }

    /// Sends a command to a bridge bot and returns the bot's replies that arrive within `wait` seconds.
    func ask(_ bridge: String, _ command: String, wait: Double = 8) async throws -> [Message] {
        let room = try await managementRoom(for: bridge)
        let bot = botID(bridge)
        let before = rooms[room]?.messages.count ?? 0
        await sendText(room, command)
        let deadline = Date().addingTimeInterval(wait)
        var lastCount = before
        var quietSince = Date()
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 400_000_000)
            let count = rooms[room]?.messages.count ?? 0
            if count != lastCount { lastCount = count; quietSince = Date() }
            let replies = (rooms[room]?.messages.dropFirst(before) ?? []).filter { $0.sender == bot }
            // Stop once the bot has replied and gone quiet for a moment.
            if !replies.isEmpty, Date().timeIntervalSince(quietSince) > 1.5 { break }
        }
        return Array((rooms[room]?.messages.dropFirst(before) ?? []).filter { $0.sender == bot })
    }
}
