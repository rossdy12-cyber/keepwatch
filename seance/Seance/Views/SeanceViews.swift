import SwiftUI

// MARK: Chat list

struct ChatsView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @AppStorage("seance.showAll") private var showAll = false
    @State private var query = ""
    @State private var showNewChat = false
    @State private var path: [String] = []

    private var chats: [Room] {
        matrix.rooms.values
            .filter { !$0.isSpace }
            .filter { showAll || $0.bridge?.protocolID == "whatsapp" || ($0.isInvite && ($0.inviter ?? "").contains("whatsapp")) }
            .filter { query.isEmpty || matrix.title($0).localizedCaseInsensitiveContains(query) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private var linked: Bool { matrix.rooms.values.contains { $0.bridge?.protocolID == "whatsapp" } }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GothicBackground()
                if chats.isEmpty {
                    VStack(spacing: 14) {
                        if !matrix.initialSyncDone {
                            ProgressView().tint(Theme.blood).scaleEffect(1.4)
                            Text("Summoning…").font(Theme.serifItalic(16)).foregroundStyle(Theme.ash)
                        } else if !linked && !showAll {
                            Text("✠").font(.system(size: 34)).foregroundStyle(Theme.crimson)
                            Text("No spirits answer").font(Theme.gothic(32)).foregroundStyle(Theme.bone)
                            Text("Link your WhatsApp to bring your chats here.")
                                .font(Theme.serifItalic(16)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
                            NavigationLink(value: "link") { Text("Link WhatsApp") }
                                .buttonStyle(CrimsonButtonStyle())
                                .padding(.horizontal, 40)
                        } else {
                            Text("Nothing found").font(Theme.gothic(30)).foregroundStyle(Theme.bone)
                        }
                    }
                    .padding(30)
                } else {
                    List(chats) { room in
                        NavigationLink(value: room.id) { ChatRow(room: room) }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.line)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await matrix.leave(room.id) }
                                } label: { Label("Leave", systemImage: "door.left.hand.open") }
                                .tint(Theme.crimson)
                                Button {
                                    matrix.markRead(room.id)
                                } label: { Label("Read", systemImage: "envelope.open") }
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Séance")
            .searchable(text: $query, prompt: Text("Search chats"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let problem = matrix.connectionProblem {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.ember)
                            .accessibilityLabel(problem)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showNewChat = true } label: { Label("New chat", systemImage: "square.and.pencil") }
                        Toggle(isOn: $showAll) { Label("Show every Matrix room", systemImage: "tray.2") }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(for: String.self) { value in
                if value == "link" {
                    LinkWhatsAppView()
                } else {
                    ChatView(roomID: value)
                }
            }
            .onReceive(MatrixPush.shared.$openRoomID) { room in
                guard let room else { return }
                MatrixPush.shared.openRoomID = nil
                path = [room]
            }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet { roomID in
                    showNewChat = false
                    if let roomID { path.append(roomID) }
                }
                .presentationDetents([.medium])
                .presentationBackground(Theme.void)
            }
        }
    }
}

struct ChatRow: View {
    @EnvironmentObject private var matrix: MatrixStore
    let room: Room

    private var preview: String {
        if room.isInvite { return "Invitation" }
        if !room.typing.isEmpty { return "typing…" }
        guard let last = room.lastMessage else { return "" }
        let who: String
        if last.sender == matrix.userID { who = "You: " }
        else if !(room.isDirect || room.joinedCount <= 2) { who = matrix.displayName(last.sender, in: room) + ": " }
        else { who = "" }
        return who + summary(last)
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(mxc: matrix.roomAvatar(room), name: matrix.title(room), size: 50)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(matrix.title(room))
                        .font(Theme.serif(17, weight: room.unread > 0 ? .semibold : .regular))
                        .foregroundStyle(Theme.bone)
                        .lineLimit(1)
                    Spacer()
                    Text(room.lastActivity == .distantPast ? "" : room.lastActivity.mailStamp)
                        .font(Theme.engraved(11))
                        .foregroundStyle(room.unread > 0 ? Theme.ember : Theme.ash)
                }
                HStack {
                    Text(preview)
                        .font(room.typing.isEmpty ? Theme.serif(14) : Theme.serifItalic(14))
                        .foregroundStyle(room.typing.isEmpty ? Theme.ash : Theme.ember)
                        .lineLimit(2)
                    Spacer()
                    if room.unread > 0 {
                        Text("\(room.unread)")
                            .font(Theme.engraved(11))
                            .foregroundStyle(Theme.bone)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.crimson, in: Capsule())
                            .shadow(color: Theme.blood, radius: 4)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Chat

struct ChatView: View {
    @EnvironmentObject private var matrix: MatrixStore
    let roomID: String
    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var loadingOlder = false

    private var room: Room? { matrix.rooms[roomID] }
    private var isGroup: Bool { !(room?.isDirect ?? true) && (room?.joinedCount ?? 0) > 2 }

    var body: some View {
        ZStack {
            GothicBackground()
            if let room {
                if room.isInvite {
                    VStack(spacing: 16) {
                        Text("\(matrix.displayName(room.inviter ?? "", in: room)) invited you").font(Theme.serif(17)).foregroundStyle(Theme.bone)
                        Button("Join") { Task { await matrix.acceptInvite(roomID) } }.buttonStyle(CrimsonButtonStyle()).padding(.horizontal, 60)
                    }
                } else {
                    VStack(spacing: 0) {
                        messageList(room)
                        Composer(roomID: roomID, replyTo: $replyTo, editing: $editing)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let room {
                    HStack(spacing: 8) {
                        AvatarView(mxc: matrix.roomAvatar(room), name: matrix.title(room), size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(matrix.title(room)).font(Theme.serif(16, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(1)
                            Text(subtitle(room)).font(Theme.serifItalic(11)).foregroundStyle(room.typing.isEmpty ? Theme.ash : Theme.ember).lineLimit(1)
                        }
                    }
                }
            }
        }
        .onAppear { matrix.markRead(roomID) }
        .onChange(of: room?.messages.count) { _, _ in matrix.markRead(roomID) }
        .onDisappear { AudioPlayback.shared.stop() }
    }

    private func subtitle(_ room: Room) -> String {
        if !room.typing.isEmpty {
            return isGroup ? room.typing.map { matrix.displayName($0, in: room) }.joined(separator: ", ") + " typing…" : "typing…"
        }
        return isGroup ? "\(room.joinedCount) members" : (room.bridge != nil ? "WhatsApp" : "")
    }

    private func messageList(_ room: Room) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !room.reachedStart {
                        ProgressView().tint(Theme.blood).padding()
                            .onAppear {
                                guard !loadingOlder else { return }
                                loadingOlder = true
                                let anchor = room.messages.first?.id
                                Task {
                                    await matrix.loadOlder(roomID)
                                    loadingOlder = false
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }
                    }
                    ForEach(Array(room.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? room.messages[index - 1] : nil
                        if previous == nil || !Calendar.current.isDate(previous!.date, inSameDayAs: message.date) {
                            Text(dayHeader(message.date).uppercased())
                                .font(Theme.engraved(10)).tracking(1.5).foregroundStyle(Theme.ash)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Theme.surface.opacity(0.8), in: Capsule())
                                .padding(.vertical, 8)
                        }
                        Bubble(message: message, room: room,
                               showSender: isGroup && message.sender != matrix.userID && previous?.sender != message.sender,
                               replyTo: $replyTo, editing: $editing)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: room.messages.last?.id) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct Bubble: View {
    @EnvironmentObject private var matrix: MatrixStore
    let message: Message
    let room: Room
    let showSender: Bool
    @Binding var replyTo: Message?
    @Binding var editing: Message?

    private var mine: Bool { message.sender == matrix.userID }
    private static let quick = ["❤️", "😂", "😮", "😢", "🙏", "👍"]

    var body: some View {
        if message.kind == .notice && !mine && message.sender.hasSuffix("bot:" + matrix.serverName) {
            Text(message.body).font(Theme.serifItalic(12)).foregroundStyle(Theme.ash).multilineTextAlignment(.center).padding(.vertical, 4)
        } else {
            HStack {
                if mine { Spacer(minLength: 50) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    VStack(alignment: .leading, spacing: 5) {
                        if showSender {
                            Text(matrix.displayName(message.sender, in: room))
                                .font(Theme.engraved(11))
                                .foregroundStyle(senderColor(message.sender))
                        }
                        if let reply = message.replyTo {
                            ReplyQuote(eventID: reply, room: room)
                        }
                        MessageContent(message: message, mine: mine)
                        HStack(spacing: 4) {
                            if message.edited { Text("edited").font(Theme.serifItalic(10)) }
                            Text(message.date.formatted(date: .omitted, time: .shortened)).font(Theme.engraved(9))
                            if mine { tick }
                        }
                        .foregroundStyle(mine ? Theme.bone.opacity(0.7) : Theme.ash)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(bubbleBackground)
                    .clipShape(BubbleShape(mine: mine))
                    .overlay(BubbleShape(mine: mine).stroke(mine ? Theme.blood.opacity(0.6) : Theme.line, lineWidth: 1))
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu { menu }
                    ReactionsRow(message: message, roomID: room.id)
                }
                if !mine { Spacer(minLength: 50) }
            }
            .opacity(message.failed ? 0.5 : 1)
            .swipeToReply { replyTo = message }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if mine {
            LinearGradient(colors: [Theme.blood.opacity(0.85), Theme.crimson], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Theme.raised
        }
    }

    @ViewBuilder
    private var tick: some View {
        if message.failed {
            Image(systemName: "exclamationmark.circle").font(.system(size: 10))
        } else if message.pending {
            Image(systemName: "clock").font(.system(size: 9))
        } else if matrix.isRead(message, in: room) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.bone)
        } else {
            Image(systemName: "checkmark").font(.system(size: 9))
        }
    }

    @ViewBuilder
    private var menu: some View {
        ControlGroup {
            ForEach(Self.quick, id: \.self) { emoji in
                Button(emoji) { Task { await matrix.react(room.id, to: message, key: emoji) } }
            }
        }
        Button { replyTo = message } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        if !message.body.isEmpty {
            Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if mine && message.kind == .text {
            Button { editing = message } label: { Label("Edit", systemImage: "pencil") }
        }
        if mine && message.kind != .redacted {
            Button(role: .destructive) { Task { await matrix.delete(room.id, message) } } label: { Label("Delete for everyone", systemImage: "trash") }
        }
    }

    private func senderColor(_ user: String) -> Color {
        let palette: [Color] = [Theme.ember, Color(red: 0.85, green: 0.6, blue: 0.4), Color(red: 0.75, green: 0.55, blue: 0.85),
                                Color(red: 0.55, green: 0.75, blue: 0.7), Color(red: 0.9, green: 0.75, blue: 0.5), Color(red: 0.6, green: 0.7, blue: 0.95)]
        let hash = user.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}

struct BubbleShape: Shape {
    let mine: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        var path = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: mine ? r : 4, bottomLeading: r, bottomTrailing: r, topTrailing: mine ? 4 : r))
        path.closeSubpath()
        return path
    }
}

struct SwipeToReply: ViewModifier {
    let action: () -> Void
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .overlay(alignment: .leading) {
                if offset > 20 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(Theme.ember)
                        .opacity(Double(min(1, offset / 60)))
                        .offset(x: offset - 30)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard value.translation.width > 0, abs(value.translation.height) < 30 else { return }
                        offset = min(80, value.translation.width)
                    }
                    .onEnded { _ in
                        if offset > 60 {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            action()
                        }
                        withAnimation(.spring(duration: 0.25)) { offset = 0 }
                    }
            )
    }
}

extension View {
    func swipeToReply(_ action: @escaping () -> Void) -> some View { modifier(SwipeToReply(action: action)) }
}

// MARK: New chat

struct NewChatSheet: View {
    @EnvironmentObject private var matrix: MatrixStore
    let done: (String?) -> Void
    @State private var number = ""
    @State private var working = false
    @State private var reply: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A new whisper").font(Theme.gothic(32)).foregroundStyle(Theme.bone)
            InscribedField(label: "WhatsApp number", text: $number, prompt: "+44 7700 900123", keyboard: .phonePad)
            if let reply {
                Text(reply).font(Theme.serifItalic(14)).foregroundStyle(Theme.ash)
            }
            Button {
                Task {
                    working = true
                    defer { working = false }
                    let digits = "+" + number.filter(\.isNumber)
                    let before = Set(matrix.rooms.keys)
                    do {
                        let replies = try await matrix.ask("whatsapp", "start-chat \(digits)", wait: 10)
                        reply = replies.map(\.body).joined(separator: "\n")
                        // The bridge opens (or reuses) a chat; find it.
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        let new = matrix.rooms.values.first { !before.contains($0.id) && $0.bridge?.protocolID == "whatsapp" }
                        if let new { done(new.id) }
                    } catch {
                        reply = error.localizedDescription
                    }
                }
            } label: {
                HStack { if working { ProgressView().tint(Theme.bone) }; Text("Begin") }
            }
            .buttonStyle(CrimsonButtonStyle())
            .disabled(number.filter(\.isNumber).count < 7 || working)
        }
        .padding(24)
    }
}

// MARK: Linking WhatsApp

struct LinkWhatsAppView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @State private var number = ""
    @State private var stage = Stage.enterNumber
    @State private var code: String?
    @State private var log: [String] = []
    @State private var working = false

    enum Stage { case enterNumber, waitingForCode, linked }

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Bind WhatsApp").font(Theme.gothic(40)).foregroundStyle(Theme.bone)
                    Text("Séance links to your WhatsApp the way WhatsApp Web does. Your phone stays the main device.")
                        .font(Theme.serifItalic(15)).foregroundStyle(Theme.ash)
                    switch stage {
                    case .enterNumber:
                        InscribedField(label: "Your WhatsApp number", text: $number, prompt: "+44 7700 900123", keyboard: .phonePad)
                        Button {
                            Task { await requestCode() }
                        } label: {
                            HStack { if working { ProgressView().tint(Theme.bone) }; Text("Get a linking code") }
                        }
                        .buttonStyle(CrimsonButtonStyle())
                        .disabled(working || number.filter(\.isNumber).count < 7)
                    case .waitingForCode:
                        if let code {
                            Text(code)
                                .font(.system(size: 40, weight: .bold, design: .monospaced))
                                .tracking(4)
                                .foregroundStyle(Theme.bone)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.blood, lineWidth: 2))
                                .shadow(color: Theme.crimson, radius: 14)
                                .textSelection(.enabled)
                            VStack(alignment: .leading, spacing: 8) {
                                step(1, "Open WhatsApp on your phone.")
                                step(2, "Settings → Linked Devices → Link a Device.")
                                step(3, "Tap “Link with phone number instead”.")
                                step(4, "Type the code above. It expires after a few minutes.")
                            }
                            Button("Copy code") { UIPasteboard.general.string = code.replacingOccurrences(of: "-", with: "") }
                                .buttonStyle(CrimsonButtonStyle(filled: false))
                        } else {
                            ProgressView("Waiting for the code…").tint(Theme.blood).foregroundStyle(Theme.ash)
                        }
                    case .linked:
                        Label("WhatsApp is linked. Your chats will appear as they sync.", systemImage: "checkmark.seal.fill")
                            .font(Theme.serif(17)).foregroundStyle(Theme.ember)
                    }
                    if !log.isEmpty {
                        OrnamentDivider()
                        Text("FROM THE BRIDGE").font(Theme.engraved(11)).tracking(2).foregroundStyle(Theme.ash)
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Theme.serif(13)).foregroundStyle(Theme.ash).textSelection(.enabled)
                        }
                    }
                }
                .padding(22)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: stage) {
            guard stage == .waitingForCode else { return }
            await watchForResult()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(Theme.gothic(22)).foregroundStyle(Theme.blood).frame(width: 20)
            Text(text).font(Theme.serif(16)).foregroundStyle(Theme.bone)
        }
    }

    private func requestCode() async {
        working = true
        defer { working = false }
        do {
            _ = try await matrix.ask("whatsapp", "cancel", wait: 2)
            let prompt = try await matrix.ask("whatsapp", "login phone", wait: 6)
            log += prompt.map(\.body)
            let replies = try await matrix.ask("whatsapp", "+" + number.filter(\.isNumber), wait: 15)
            log += replies.map(\.body)
            code = findCode(replies.map(\.body).joined(separator: "\n"))
            stage = .waitingForCode
        } catch {
            log.append(error.localizedDescription)
        }
    }

    /// Keeps reading the bot's messages until it reports success (or a new code).
    private func watchForResult() async {
        guard let roomID = try? await matrix.managementRoom(for: "whatsapp") else { return }
        var seen = matrix.rooms[roomID]?.messages.count ?? 0
        while !Task.isCancelled && stage == .waitingForCode {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let messages = matrix.rooms[roomID]?.messages ?? []
            guard messages.count > seen else { continue }
            for message in messages[seen...] where message.sender == matrix.botID("whatsapp") {
                log.append(message.body)
                if code == nil, let found = findCode(message.body) { code = found }
                let lower = message.body.lowercased()
                if lower.contains("successfully logged in") || lower.contains("logged in as") {
                    stage = .linked
                }
            }
            seen = messages.count
        }
    }

    private func findCode(_ text: String) -> String? {
        let pattern = #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}

// MARK: Settings

struct SanctumView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @State private var bridgeStatus: String?
    @State private var confirmSignOut = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    Section {
                        HStack(spacing: 12) {
                            Sigil(name: matrix.userID.dropFirst().description, size: 46)
                            VStack(alignment: .leading) {
                                Text(matrix.userID).font(Theme.serif(16, weight: .semibold)).foregroundStyle(Theme.bone)
                                Text(matrix.session?.homeserver ?? "").font(Theme.serifItalic(13)).foregroundStyle(Theme.ash)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        NavigationLink { LinkWhatsAppView() } label: { Label("Link WhatsApp", systemImage: "link") }
                        Button {
                            Task {
                                checking = true
                                defer { checking = false }
                                bridgeStatus = (try? await matrix.ask("whatsapp", "list-logins", wait: 5))?.map(\.body).joined(separator: "\n") ?? "The bridge didn't answer."
                            }
                        } label: {
                            HStack { Label("Check the link", systemImage: "stethoscope"); Spacer(); if checking { ProgressView().tint(Theme.blood) } }
                        }
                        if let bridgeStatus {
                            Text(bridgeStatus).font(Theme.serif(13)).foregroundStyle(Theme.ash).textSelection(.enabled)
                        }
                        NavigationLink {
                            BridgeConsole()
                        } label: { Label("Bridge console", systemImage: "terminal") }
                        NavigationLink {
                            PushSettingsView()
                        } label: { Label("Notifications", systemImage: "bell.badge") }
                    } header: {
                        Text("WHATSAPP").font(Theme.engraved(12)).tracking(2).foregroundStyle(Theme.ash)
                    } footer: {
                        Text("The console talks to the WhatsApp bridge directly. Type help to see every command, or logout to unlink.")
                            .font(Theme.serifItalic(12)).foregroundStyle(Theme.ash)
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        Button("Sign out of Séance", role: .destructive) { confirmSignOut = true }
                    }
                    .listRowBackground(Theme.surface)
                }
                .font(Theme.serif(16))
                .foregroundStyle(Theme.bone)
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Sanctum")
            .confirmationDialog("Sign out? WhatsApp stays linked on the server.", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await matrix.signOut() } }
            }
        }
    }
}

/// A plain chat with the bridge bot, for anything the app doesn't wrap.
struct BridgeConsole: View {
    @EnvironmentObject private var matrix: MatrixStore
    @State private var roomID: String?

    var body: some View {
        Group {
            if let roomID {
                ChatView(roomID: roomID)
            } else {
                ZStack { GothicBackground(); ProgressView().tint(Theme.blood) }
            }
        }
        .task { roomID = try? await matrix.managementRoom(for: "whatsapp") }
    }
}
