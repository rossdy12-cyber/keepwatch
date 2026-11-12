import SwiftUI

/// One conversation on the Nocturne server, as returned by GET /api/me.
struct ChatRoom: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let last: RelayMessage?

    static func == (a: ChatRoom, b: ChatRoom) -> Bool { a.id == b.id && a.title == b.title && a.last?.id == b.last?.id }
}

struct MeResponse: Decodable {
    let name: String
    let rooms: [ChatRoom]
}

/// Who this device is signed in as. Servers with per-person logins answer /api/me; older ones don't (nil).
enum Account {
    @MainActor
    static func fetchMe(_ store: Store) async -> MeResponse? {
        let base = ServerAddress.normalize(store.relayURL)
        guard !base.isEmpty, let url = URL(string: base + "/api/me") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        if !store.relayToken.isEmpty { r.setValue("Bearer \(store.relayToken)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await netSession.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let me = try? JSONDecoder().decode(MeResponse.self, from: data) else { return nil }
        return me
    }

    /// Applies the server's view of this person: their name, and the room when there's only one.
    @MainActor
    static func apply(_ me: MeResponse, to store: Store) {
        if !me.name.isEmpty { store.displayName = me.name }
        store.rooms = me.rooms
        if me.rooms.count == 1, let only = me.rooms.first {
            store.chatRoom = only.id
            store.partnerName = only.title
        } else if let current = me.rooms.first(where: { $0.id == store.chatRoom }) {
            store.partnerName = current.title
        }
    }

    static func lastSeen(_ room: String) -> Int { UserDefaults.standard.integer(forKey: "seen_\(room)") }
    static func markSeen(_ room: String, _ id: Int) {
        if id > lastSeen(room) { UserDefaults.standard.set(id, forKey: "seen_\(room)") }
    }
}

/// The Messages module: a list of conversations when there's more than one, otherwise straight into the chat.
struct MessagesHome: View {
    @EnvironmentObject var store: Store
    @State private var showingList = true
    private var theme: GothicTheme { store.theme }

    var body: some View {
        Group {
            if store.rooms.count > 1 && showingList {
                ConversationList { room in
                    store.chatRoom = room.id
                    store.partnerName = room.title
                    showingList = false
                }
            } else {
                MessagesView(onShowList: store.rooms.count > 1 ? { showingList = true } : nil)
                    .id(store.chatRoom)
            }
        }
        .task {
            if let pending = store.pendingRoom {
                store.chatRoom = pending
                store.pendingRoom = nil
                showingList = false
            }
            await refresh()
        }
        .onChange(of: store.pendingRoom) { pending in
            guard let pending else { return }
            store.chatRoom = pending
            store.pendingRoom = nil
            showingList = false
            if let r = store.rooms.first(where: { $0.id == pending }) { store.partnerName = r.title }
        }
    }

    private func refresh() async {
        if let me = await Account.fetchMe(store) {
            Account.apply(me, to: store)
            PushManager.shared.reregister()
        }
    }
}

struct ConversationList: View {
    @EnvironmentObject var store: Store
    let open: (ChatRoom) -> Void
    private var theme: GothicTheme { store.theme }
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GothicTitle(text: "Messages", theme: theme, size: 26)
                .padding(.horizontal, 20).padding(.top, 50).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.rooms) { room in
                        Button { open(room) } label: { row(room) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            Task { if let me = await Account.fetchMe(store) { store.rooms = me.rooms } }
        }
    }

    private func row(_ room: ChatRoom) -> some View {
        let unread = (room.last?.id ?? 0) > Account.lastSeen(room.id) && room.last?.sender != store.displayName
        return HStack(spacing: 14) {
            Text(String(room.title.prefix(1)).uppercased())
                .font(.system(size: 22, design: .serif))
                .frame(width: 48, height: 48)
                .background(Circle().fill(theme.accentColor.opacity(0.25)))
                .foregroundStyle(theme.accent2Color)
            VStack(alignment: .leading, spacing: 3) {
                Text(room.title).font(.system(.headline, design: .serif)).foregroundStyle(theme.textColor)
                Text(room.last?.text ?? "No messages yet")
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(unread ? theme.textColor : theme.mutedColor)
            }
            Spacer()
            if unread { Circle().fill(theme.accent2Color).frame(width: 10, height: 10) }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
