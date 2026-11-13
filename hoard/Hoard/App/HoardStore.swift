import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently played"
    case playtime = "Most played"
    case name = "Name"
    case unplayed = "Pile of shame"
    var id: String { rawValue }
}

@MainActor
final class HoardStore: ObservableObject {
    @Published private(set) var apiKey: String
    @Published private(set) var steamID: String
    @Published private(set) var me: Player?
    @Published private(set) var level: Int?
    @Published private(set) var games: [OwnedGame] = []
    @Published private(set) var friends: [Player] = []
    @Published private(set) var wishlist: [WishlistEntry] = []
    @Published private(set) var loadingLibrary = false
    @Published private(set) var loadingWishlist = false
    @Published var errorMessage: String?
    @Published var friendsError: String?

    init() {
        apiKey = Keychain.read(account: "apikey") ?? ""
        steamID = UserDefaults.standard.string(forKey: "hoard.steamid") ?? ""
    }

    var isConfigured: Bool { !apiKey.isEmpty && !steamID.isEmpty }

    var totalMinutes: Int { games.reduce(0) { $0 + $1.minutes } }
    var unplayedCount: Int { games.filter { $0.minutes == 0 }.count }

    func configure(key: String, profile: String) async throws {
        // Pick the 32-character key out of whatever was pasted (labels, spaces, invisible characters).
        guard let range = key.range(of: "[0-9A-Fa-f]{32}", options: .regularExpression) else {
            throw SteamError.server("That doesn't look like a Steam Web API key. It's 32 letters and numbers, shown on steamcommunity.com/dev/apikey after “Key:”.")
        }
        let trimmedKey = String(key[range]).uppercased()
        // Check the key on its own first, so a key problem and a profile problem give different messages.
        do {
            _ = try await Steam.players(["76561197960287930"], key: trimmedKey)
        } catch SteamError.badKey {
            throw SteamError.server("Steam rejected this key. Check it matches the one on steamcommunity.com/dev/apikey exactly. If you've only just made it, wait a few minutes and try again.")
        }
        let id = try await Steam.resolve(profile, key: trimmedKey)
        let players = try await Steam.players([id], key: trimmedKey)
        guard let player = players.first else { throw SteamError.notFound(profile) }
        Keychain.save(trimmedKey, account: "apikey")
        UserDefaults.standard.set(id, forKey: "hoard.steamid")
        apiKey = trimmedKey
        steamID = id
        me = player
        await refreshAll()
    }

    func forget() {
        Keychain.save("", account: "apikey")
        UserDefaults.standard.removeObject(forKey: "hoard.steamid")
        apiKey = ""
        steamID = ""
        me = nil
        games = []
        friends = []
        wishlist = []
    }

    func refreshAll() async {
        async let a: Void = refreshProfile()
        async let b: Void = refreshLibrary()
        async let c: Void = refreshFriends()
        _ = await (a, b, c)
    }

    func refreshProfile() async {
        guard isConfigured else { return }
        if let player = try? await Steam.players([steamID], key: apiKey).first { me = player }
        level = await Steam.level(steamID, key: apiKey)
    }

    func refreshLibrary() async {
        guard isConfigured else { return }
        loadingLibrary = true
        defer { loadingLibrary = false }
        do {
            games = try await Steam.ownedGames(steamID, key: apiKey)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshFriends() async {
        guard isConfigured else { return }
        do {
            let list = try await Steam.friends(steamID, key: apiKey)
            friends = list.sorted { a, b in
                if a.isInGame != b.isInGame { return a.isInGame }
                if a.isOnline != b.isOnline { return a.isOnline }
                return a.personaname.localizedCaseInsensitiveCompare(b.personaname) == .orderedAscending
            }
            friendsError = nil
        } catch {
            friendsError = error.localizedDescription
        }
    }

    func refreshWishlist() async {
        guard isConfigured else { return }
        loadingWishlist = true
        defer { loadingWishlist = false }
        do {
            var entries = try await Steam.wishlist(steamID, key: apiKey)
            let prices = await Steam.prices(entries.map(\.appid))
            for index in entries.indices {
                if let price = prices[entries[index].appid] {
                    entries[index].price = price
                    entries[index].free = price == nil
                }
            }
            wishlist = entries.sorted { ($0.price?.discount_percent ?? 0, -$0.priority) > ($1.price?.discount_percent ?? 0, -$1.priority) }
            // Names come one by one from the store; fill them in as they arrive.
            for entry in wishlist where entry.name == nil {
                if let name = await Steam.name(entry.appid), let index = wishlist.firstIndex(where: { $0.appid == entry.appid }) {
                    wishlist[index].name = name
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sorted(_ sort: LibrarySort, query: String) -> [OwnedGame] {
        var list = games
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .recent:
            return list.sorted { ($0.rtime_last_played ?? 0) > ($1.rtime_last_played ?? 0) }
        case .playtime:
            return list.sorted { $0.minutes > $1.minutes }
        case .name:
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .unplayed:
            return list.filter { $0.minutes == 0 }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}
