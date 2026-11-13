import SwiftUI

@main
struct ConclaveApp: App {
    @UIApplicationDelegateAdaptor(MatrixAppDelegate.self) private var appDelegate
    @StateObject private var matrix = MatrixStore(keychainService: "app.keepwatch.conclave")
    @Environment(\.scenePhase) private var phase

    init() {
        Theme.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if matrix.session == nil {
                    MatrixSignIn(appName: "Conclave", tagline: "THE GATHERING OF COVENS", deviceName: "Conclave on iPhone")
                } else {
                    ConclaveHome()
                        .onAppear { matrix.start() }
                }
            }
            .environmentObject(matrix)
            .onChange(of: matrix.initialSyncDone) { _, done in
                guard done else { return }
                MatrixPush.shared.matrix = matrix
                Task { await MatrixPush.shared.sync() }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.blood)
            .overlay(alignment: .top) {
                if let message = matrix.errorMessage {
                    Text(message)
                        .font(Theme.serif(14)).foregroundStyle(Theme.bone)
                        .padding(12).frame(maxWidth: .infinity)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
                        .padding(.horizontal).padding(.top, 50)
                        .onTapGesture { matrix.errorMessage = nil }
                        .task { try? await Task.sleep(nanoseconds: 5_000_000_000); matrix.errorMessage = nil }
                }
            }
        }
        .onChange(of: phase) { _, now in
            if now == .active, matrix.session != nil { matrix.resume() }
        }
    }
}

/// A Discord server as the bridge describes it.
struct Guild: Identifiable, Hashable {
    let id: String
    var name: String
    var avatar: String?
    var channels: [Room]
    var unread: Int { channels.reduce(0) { $0 + $1.unread } }
    var mentions: Int { channels.reduce(0) { $0 + $1.highlights } }
}

extension MatrixStore {
    var discordRooms: [Room] {
        rooms.values.filter { ($0.bridge?.protocolID.hasPrefix("discord") ?? false) && !$0.isSpace }
    }

    var guilds: [Guild] {
        var byID: [String: Guild] = [:]
        for room in discordRooms {
            guard let id = room.bridge?.networkID else { continue }
            var guild = byID[id] ?? Guild(id: id, name: room.bridge?.networkName ?? "Server", avatar: room.bridge?.networkAvatar, channels: [])
            guild.channels.append(room)
            byID[id] = guild
        }
        return byID.values
            .map { guild in
                var sorted = guild
                sorted.channels.sort { channelName($0).localizedCaseInsensitiveCompare(channelName($1)) == .orderedAscending }
                return sorted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Direct messages and group DMs: Discord rooms with no server.
    var discordDMs: [Room] {
        discordRooms.filter { $0.bridge?.networkID == nil }.sorted { $0.lastActivity > $1.lastActivity }
    }

    func channelName(_ room: Room) -> String {
        let name = room.bridge?.channelName ?? room.name ?? title(room)
        return name.hasPrefix("#") ? String(name.dropFirst()) : name
    }
}
