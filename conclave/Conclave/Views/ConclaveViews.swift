import SwiftUI

// MARK: Home: server rail + channel list

struct ConclaveHome: View {
    @EnvironmentObject private var matrix: MatrixStore
    @AppStorage("conclave.selected") private var selected = "dms"
    @State private var path: [String] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GothicBackground()
                HStack(spacing: 0) {
                    rail
                    Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
                    channelPane
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { ChannelView(roomID: $0) }
            .sheet(isPresented: $showSettings) {
                ConclaveSettings().presentationBackground(Theme.void)
            }
            .onReceive(MatrixPush.shared.$openRoomID) { room in
                guard let room else { return }
                MatrixPush.shared.openRoomID = nil
                showSettings = false
                path = [room]
            }
        }
    }

    // MARK: Rail

    private var rail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                railButton(id: "dms", unread: matrix.discordDMs.filter { $0.unread > 0 }.count) {
                    ZStack {
                        Theme.crimson
                        Image(systemName: "envelope.fill").foregroundStyle(Theme.bone)
                    }
                }
                Rectangle().fill(Theme.line).frame(width: 30, height: 2)
                ForEach(matrix.guilds) { guild in
                    railButton(id: guild.id, unread: guild.unread, mentions: guild.mentions) {
                        if let avatar = guild.avatar {
                            MXCImage(mxc: avatar, thumbnail: 96)
                        } else {
                            ZStack {
                                Theme.raised
                                Text(initials(guild.name)).font(Theme.engraved(14)).foregroundStyle(Theme.bone)
                            }
                        }
                    }
                    .accessibilityLabel(guild.name)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ember)
                        .frame(width: 48, height: 48)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
                }
                .accessibilityLabel("Add or remove servers")
            }
            .padding(.vertical, 12)
        }
        .frame(width: 70)
        .background(Theme.void.opacity(0.9))
    }

    private func railButton<Icon: View>(id: String, unread: Int, mentions: Int = 0, @ViewBuilder icon: () -> Icon) -> some View {
        let active = selected == id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selected = id }
        } label: {
            icon()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: active ? 14 : 24))
                .overlay(RoundedRectangle(cornerRadius: active ? 14 : 24).strokeBorder(active ? Theme.blood : Color.clear, lineWidth: 2))
                .shadow(color: active ? Theme.crimson : .clear, radius: 8)
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 {
                        Text("\(mentions)").font(Theme.engraved(10)).foregroundStyle(Theme.bone)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.blood, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.void, lineWidth: 2))
                            .offset(x: 4, y: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.bone)
                        .frame(width: 4, height: active ? 36 : (unread > 0 ? 8 : 0))
                        .offset(x: -2)
                }
        }
        .buttonStyle(.plain)
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(3).compactMap(\.first).map(String.init).joined()
    }

    // MARK: Channels

    @ViewBuilder
    private var channelPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selected == "dms" ? "Missives" : (matrix.guilds.first { $0.id == selected }?.name ?? "Conclave"))
                    .font(Theme.gothic(26))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                if matrix.connectionProblem != nil {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.ember)
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape").foregroundStyle(Theme.ash) }
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            OrnamentDivider().padding(.horizontal, 14)
            if !matrix.initialSyncDone {
                Spacer()
                ProgressView().tint(Theme.blood).frame(maxWidth: .infinity)
                Spacer()
            } else if selected == "dms" {
                dmList
            } else if let guild = matrix.guilds.first(where: { $0.id == selected }) {
                List(guild.channels) { room in
                    NavigationLink(value: room.id) {
                        HStack(spacing: 8) {
                            Text("#").font(Theme.serif(20)).foregroundStyle(Theme.ash)
                            Text(matrix.channelName(room))
                                .font(Theme.serif(16, weight: room.unread > 0 ? .semibold : .regular))
                                .foregroundStyle(room.unread > 0 ? Theme.bone : Theme.ash)
                                .lineLimit(1)
                            Spacer()
                            if room.highlights > 0 {
                                Text("\(room.highlights)").font(Theme.engraved(10)).foregroundStyle(Theme.bone)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.blood, in: Capsule())
                            } else if room.unread > 0 {
                                Circle().fill(Theme.bone).frame(width: 6, height: 6)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                emptyServers
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var dmList: some View {
        if matrix.discordDMs.isEmpty {
            emptyServers
        } else {
            List(matrix.discordDMs) { room in
                NavigationLink(value: room.id) {
                    HStack(spacing: 10) {
                        AvatarView(mxc: matrix.roomAvatar(room), name: matrix.title(room), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(matrix.title(room)).font(Theme.serif(15, weight: room.unread > 0 ? .semibold : .regular))
                                .foregroundStyle(Theme.bone).lineLimit(1)
                            if let last = room.lastMessage {
                                Text(summary(last)).font(Theme.serif(12)).foregroundStyle(Theme.ash).lineLimit(1)
                            }
                        }
                        Spacer()
                        if room.unread > 0 {
                            Text("\(room.unread)").font(Theme.engraved(10)).foregroundStyle(Theme.bone)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.blood, in: Capsule())
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyServers: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("✠").font(.system(size: 30)).foregroundStyle(Theme.crimson)
            Text(selected == "dms" ? "No missives yet" : "An empty hall").font(Theme.gothic(26)).foregroundStyle(Theme.bone)
            Text("Link Discord, then choose which servers to bring across.")
                .font(Theme.serifItalic(14)).foregroundStyle(Theme.ash).multilineTextAlignment(.center)
            Button("Open settings") { showSettings = true }
                .buttonStyle(CrimsonButtonStyle())
                .padding(.horizontal, 20)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Channel

struct ChannelView: View {
    @EnvironmentObject private var matrix: MatrixStore
    let roomID: String
    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var loadingOlder = false

    private var room: Room? { matrix.rooms[roomID] }

    var body: some View {
        ZStack {
            GothicBackground()
            if let room {
                VStack(spacing: 0) {
                    messages(room)
                    if !room.typing.isEmpty {
                        Text(room.typing.map { matrix.displayName($0, in: room) }.joined(separator: ", ") + (room.typing.count == 1 ? " is typing…" : " are typing…"))
                            .font(Theme.serifItalic(12)).foregroundStyle(Theme.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 2)
                    }
                    Composer(roomID: roomID, replyTo: $replyTo, editing: $editing,
                             placeholder: room.bridge?.networkID == nil ? "Message \(matrix.title(room))" : "Message #\(matrix.channelName(room))")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let room {
                    VStack(spacing: 0) {
                        Text(room.bridge?.networkID == nil ? matrix.title(room) : "# " + matrix.channelName(room))
                            .font(Theme.serif(16, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(1)
                        if let topic = room.topic, !topic.isEmpty {
                            Text(topic).font(Theme.serifItalic(10)).foregroundStyle(Theme.ash).lineLimit(1)
                        }
                    }
                }
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .onAppear { matrix.markRead(roomID) }
        .onChange(of: room?.messages.count) { _, _ in matrix.markRead(roomID) }
        .onDisappear { AudioPlayback.shared.stop() }
    }

    private func messages(_ room: Room) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !room.reachedStart {
                        ProgressView().tint(Theme.blood).frame(maxWidth: .infinity).padding()
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
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Welcome to #\(matrix.channelName(room))").font(Theme.gothic(28)).foregroundStyle(Theme.bone)
                            Text("This is the start of the channel.").font(Theme.serifItalic(14)).foregroundStyle(Theme.ash)
                        }
                        .padding(16)
                    }
                    ForEach(Array(room.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? room.messages[index - 1] : nil
                        let newDay = previous == nil || !Calendar.current.isDate(previous!.date, inSameDayAs: message.date)
                        if newDay {
                            HStack {
                                Rectangle().fill(Theme.line).frame(height: 1)
                                Text(dayHeader(message.date)).font(Theme.engraved(10)).foregroundStyle(Theme.ash).fixedSize()
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        let grouped = !newDay && previous?.sender == message.sender && message.date.timeIntervalSince(previous!.date) < 420 && message.replyTo == nil
                        ChannelMessage(message: message, room: room, grouped: grouped, replyTo: $replyTo, editing: $editing)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: room.messages.last?.id) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct ChannelMessage: View {
    @EnvironmentObject private var matrix: MatrixStore
    let message: Message
    let room: Room
    let grouped: Bool
    @Binding var replyTo: Message?
    @Binding var editing: Message?
    private static let quick = ["👍", "❤️", "😂", "😮", "🔥", "💀"]

    private var mine: Bool { message.sender == matrix.userID }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if grouped {
                Color.clear.frame(width: 38, height: 1)
            } else {
                AvatarView(mxc: matrix.avatar(message.sender, in: room), name: matrix.displayName(message.sender, in: room), size: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let reply = message.replyTo {
                    ReplyQuote(eventID: reply, room: room)
                }
                if !grouped {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(matrix.displayName(message.sender, in: room))
                            .font(Theme.serif(15, weight: .semibold))
                            .foregroundStyle(mine ? Theme.ember : nameColor(message.sender))
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(Theme.engraved(10)).foregroundStyle(Theme.ash)
                    }
                }
                MessageContent(message: message, mine: false, maxMediaWidth: 260)
                HStack(spacing: 6) {
                    if message.edited { Text("(edited)").font(Theme.serifItalic(10)).foregroundStyle(Theme.ash) }
                    if message.pending { Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(Theme.ash) }
                    if message.failed { Text("Not sent").font(Theme.serifItalic(10)).foregroundStyle(Theme.ember) }
                }
                ReactionsRow(message: message, roomID: room.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, grouped ? 2 : 10)
        .contentShape(Rectangle())
        .contextMenu {
            ControlGroup {
                ForEach(Self.quick, id: \.self) { emoji in
                    Button(emoji) { Task { await matrix.react(room.id, to: message, key: emoji) } }
                }
            }
            Button { replyTo = message } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            if !message.body.isEmpty {
                Button { UIPasteboard.general.string = message.body } label: { Label("Copy text", systemImage: "doc.on.doc") }
            }
            if mine && message.kind == .text {
                Button { editing = message } label: { Label("Edit", systemImage: "pencil") }
            }
            if mine && message.kind != .redacted {
                Button(role: .destructive) { Task { await matrix.delete(room.id, message) } } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func nameColor(_ user: String) -> Color {
        let palette: [Color] = [Theme.bone, Color(red: 0.85, green: 0.6, blue: 0.4), Color(red: 0.75, green: 0.55, blue: 0.85),
                                Color(red: 0.55, green: 0.75, blue: 0.7), Color(red: 0.9, green: 0.75, blue: 0.5), Color(red: 0.6, green: 0.7, blue: 0.95)]
        let hash = user.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}

// MARK: Settings

struct ConclaveSettings: View {
    @EnvironmentObject private var matrix: MatrixStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    Section {
                        NavigationLink { LinkDiscordView() } label: { Label("Link Discord", systemImage: "link") }
                        NavigationLink { ServersView() } label: { Label("Choose servers", systemImage: "building.columns") }
                        NavigationLink { ConsoleView() } label: { Label("Bridge console", systemImage: "terminal") }
                        NavigationLink { PushSettingsView() } label: { Label("Notifications", systemImage: "bell.badge") }
                    } header: {
                        Text("DISCORD").font(Theme.engraved(12)).tracking(2).foregroundStyle(Theme.ash)
                    } footer: {
                        Text("Discord's rules forbid automating user accounts, which is how the bridge works. Accounts are rarely banned for it, but it can happen.")
                            .font(Theme.serifItalic(12)).foregroundStyle(Theme.ash)
                    }
                    .listRowBackground(Theme.surface)
                    Section {
                        Text(matrix.userID).foregroundStyle(Theme.ash)
                        Button("Sign out of Conclave", role: .destructive) { confirmSignOut = true }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(Theme.engraved(14)) }
            }
            .confirmationDialog("Sign out? Discord stays linked on the server.", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await matrix.signOut() } }
            }
        }
    }
}

struct LinkDiscordView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @State private var token = ""
    @State private var working = false
    @State private var log: [Message] = []
    @State private var qr: String?

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Bind Discord").font(Theme.gothic(40)).foregroundStyle(Theme.bone)
                    Text("Option 1 · Token").font(Theme.engraved(13)).tracking(1.5).foregroundStyle(Theme.ember)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. On your PC, sign in at discord.com in Chrome or Edge.")
                        Text("2. Press F12 and open the Network tab. Type api in its filter box.")
                        Text("3. Click any channel in Discord, then click one of the new requests in the list.")
                        Text("4. Under Headers → Request Headers, copy the value of authorization.")
                        Text("Never paste code into the console when a website or person asks you to. Anyone with this token can use your account, so don't share it.")
                            .font(Theme.serifItalic(13))
                    }
                    .font(Theme.serif(14)).foregroundStyle(Theme.ash)
                    InscribedField(label: "Discord token", text: $token, prompt: "Paste the token", secure: true)
                    Button {
                        Task { await run("login-token user " + token.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))) }
                    } label: {
                        HStack { if working { ProgressView().tint(Theme.bone) }; Text("Link with token") }
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    .disabled(working || token.count < 20)

                    OrnamentDivider()
                    Text("Option 2 · QR code").font(Theme.engraved(13)).tracking(1.5).foregroundStyle(Theme.ember)
                    Text("Shows a code to scan with the Discord app on another phone or tablet (Settings → Scan QR Code).")
                        .font(Theme.serif(14)).foregroundStyle(Theme.ash)
                    Button { Task { await run("login-qr", wait: 60) } } label: { Text("Show QR code") }
                        .buttonStyle(CrimsonButtonStyle(filled: false))
                        .disabled(working)
                    if let qr {
                        MXCImage(mxc: qr, thumbnail: nil, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: 260)
                            .background(Color.white)
                    }
                    ForEach(log) { message in
                        Text(message.body).font(Theme.serif(13)).foregroundStyle(message.body.lowercased().contains("success") ? Theme.ember : Theme.ash)
                            .textSelection(.enabled)
                    }
                }
                .padding(22)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ command: String, wait: Double = 12) async {
        working = true
        defer { working = false }
        do {
            let replies = try await matrix.ask("discord", command, wait: wait)
            log = replies
            qr = replies.last { $0.kind == .image }?.media?.mxc
            if command.hasPrefix("login-token") { token = "" }
        } catch {
            matrix.errorMessage = error.localizedDescription
        }
    }
}

struct ServersView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @State private var lines: [String] = []
    @State private var working = false
    @State private var busyID: String?

    private struct Entry: Identifiable { let id: String; let line: String }

    private var entries: [Entry] {
        lines.compactMap { line in
            guard let range = line.range(of: #"\d{17,20}"#, options: .regularExpression) else { return nil }
            return Entry(id: String(line[range]), line: line)
        }
    }

    var body: some View {
        ZStack {
            GothicBackground()
            List {
                Section {
                    if working && entries.isEmpty {
                        ProgressView().tint(Theme.blood)
                    }
                    ForEach(entries) { entry in
                        let bridged = matrix.guilds.contains { $0.id == entry.id }
                        HStack {
                            Text(clean(entry.line, id: entry.id)).font(Theme.serif(15)).foregroundStyle(Theme.bone)
                            Spacer()
                            if busyID == entry.id {
                                ProgressView().tint(Theme.blood)
                            } else {
                                Button(bridged ? "Remove" : "Bring across") {
                                    Task { await toggle(entry.id, bridged: bridged) }
                                }
                                .font(Theme.engraved(12))
                                .foregroundStyle(bridged ? Theme.ash : Theme.ember)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    if !working && entries.isEmpty {
                        Text(lines.isEmpty ? "Link Discord first." : lines.joined(separator: "\n")).font(Theme.serif(13)).foregroundStyle(Theme.ash)
                    }
                } footer: {
                    Text("Bringing a server across creates a room for every channel you can see. Big servers take a minute.")
                        .font(Theme.serifItalic(12)).foregroundStyle(Theme.ash)
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .gothicTitle("Servers")
        .task { await load() }
    }

    private func clean(_ line: String, id: String) -> String {
        var text = line.replacingOccurrences(of: id, with: "")
        for junk in ["*", "`", "()", "[]", " - ", "  "] { text = text.replacingOccurrences(of: junk, with: " ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-:")))
    }

    private func load() async {
        working = true
        defer { working = false }
        let replies = (try? await matrix.ask("discord", "guilds status", wait: 6)) ?? []
        lines = replies.flatMap { $0.body.components(separatedBy: .newlines) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func toggle(_ id: String, bridged: Bool) async {
        busyID = id
        defer { busyID = nil }
        _ = try? await matrix.ask("discord", bridged ? "guilds unbridge \(id)" : "guilds bridge \(id) --entire", wait: 20)
        await load()
    }
}

struct ConsoleView: View {
    @EnvironmentObject private var matrix: MatrixStore
    @State private var roomID: String?

    var body: some View {
        Group {
            if let roomID {
                ChannelView(roomID: roomID)
            } else {
                ZStack { GothicBackground(); ProgressView().tint(Theme.blood) }
            }
        }
        .task { roomID = try? await matrix.managementRoom(for: "discord") }
    }
}
