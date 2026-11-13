import Foundation
import Security
import UIKit

// MARK: Models

struct OwnedGame: Decodable, Identifiable, Hashable {
    let appid: Int
    let name: String?
    let playtime_forever: Int?
    let playtime_2weeks: Int?
    let rtime_last_played: Double?
    let img_icon_url: String?

    var id: Int { appid }
    var title: String { name ?? "App \(appid)" }
    var minutes: Int { playtime_forever ?? 0 }
    var recentMinutes: Int { playtime_2weeks ?? 0 }
    var lastPlayed: Date? { (rtime_last_played ?? 0) > 0 ? Date(timeIntervalSince1970: rtime_last_played!) : nil }
    var hoursText: String { Steam.hours(minutes) }
    var capsule: URL { Steam.image(appid, "library_600x900.jpg") }
    var header: URL { Steam.image(appid, "header.jpg") }
    var hero: URL { Steam.image(appid, "library_hero.jpg") }
}

struct Player: Decodable, Identifiable, Hashable {
    let steamid: String
    let personaname: String
    let avatarfull: String?
    let personastate: Int?
    let gameextrainfo: String?
    let gameid: String?
    let lastlogoff: Double?
    let profileurl: String?
    let realname: String?
    let loccountrycode: String?
    let timecreated: Double?
    let communityvisibilitystate: Int?

    var id: String { steamid }
    var avatar: URL? { avatarfull.flatMap(URL.init(string:)) }
    var isInGame: Bool { gameextrainfo != nil }
    var status: String {
        if let game = gameextrainfo { return "Playing \(game)" }
        switch personastate ?? 0 {
        case 1: return "Online"
        case 2: return "Busy"
        case 3: return "Away"
        case 4: return "Snoozing"
        case 5: return "Looking to trade"
        case 6: return "Looking to play"
        default:
            if let off = lastlogoff, off > 0 {
                return "Last seen " + Date(timeIntervalSince1970: off).formatted(.relative(presentation: .named))
            }
            return "Offline"
        }
    }
    var isOnline: Bool { (personastate ?? 0) > 0 || isInGame }
}

struct Achievement: Identifiable, Hashable {
    let apiName: String
    let title: String
    let detail: String
    let icon: URL?
    let iconGray: URL?
    let achieved: Bool
    let unlocked: Date?
    let globalPercent: Double?
    let hidden: Bool
    var id: String { apiName }
}

struct StorePrice: Decodable, Hashable {
    let currency: String
    let initial: Int
    let final: Int
    let discount_percent: Int
    let final_formatted: String
    let initial_formatted: String?
}

struct WishlistEntry: Identifiable, Hashable {
    let appid: Int
    let priority: Int
    let added: Date?
    var name: String?
    var price: StorePrice?
    var free = false
    var id: Int { appid }
    var header: URL { Steam.image(appid, "header.jpg") }
}

enum SteamError: LocalizedError {
    case notConfigured, privateProfile, badKey, notFound(String), server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Steam Web API key and Steam ID in Sanctum."
        case .privateProfile: return "Steam returned nothing. In Steam → Profile → Edit Profile → Privacy, set “Game details” (and “Friends list”) to Public."
        case .badKey: return "Steam refused the API key. Check it at steamcommunity.com/dev/apikey."
        case .notFound(let what): return "Couldn't find the Steam profile “\(what)”."
        case .server(let text): return text
        }
    }
}

// MARK: API

enum Steam {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 48 << 20, diskCapacity: 512 << 20)
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func image(_ appid: Int, _ file: String) -> URL {
        URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appid)/\(file)")!
    }

    static func storePage(_ appid: Int) -> URL {
        URL(string: "https://store.steampowered.com/app/\(appid)")!
    }

    static func hours(_ minutes: Int) -> String {
        if minutes == 0 { return "Never played" }
        if minutes < 60 { return "\(minutes) min" }
        let h = Double(minutes) / 60
        return h < 10 ? String(format: "%.1f h", h) : "\(Int(h.rounded())) h"
    }

    private static func fetchJSON(_ urlString: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: urlString)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw SteamError.server("Couldn't reach Steam. Check your connection.")
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw SteamError.badKey }
        if code == 429 { throw SteamError.server("Steam is rate-limiting requests. Try again in a minute.") }
        guard (200..<300).contains(code) else { throw SteamError.server("Steam returned an error (HTTP \(code)).") }
        return (try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]) ?? [:]
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any, let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let api = "https://api.steampowered.com/"

    /// Accepts a 17-digit ID, a vanity name, or a profile URL.
    static func resolve(_ input: String, key: String) async throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "/profiles/") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if let range = text.range(of: "/id/") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if text.count == 17, text.allSatisfy(\.isNumber) { return text }
        let json = try await fetchJSON(api + "ISteamUser/ResolveVanityURL/v1/", ["key": key, "vanityurl": text])
        let response = json["response"] as? [String: Any]
        if let id = response?["steamid"] as? String { return id }
        throw SteamError.notFound(text)
    }

    static func players(_ ids: [String], key: String) async throws -> [Player] {
        var result: [Player] = []
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let json = try await fetchJSON(api + "ISteamUser/GetPlayerSummaries/v2/", ["key": key, "steamids": chunk.joined(separator: ",")])
            let players = (json["response"] as? [String: Any])?["players"]
            result += decode([Player].self, players) ?? []
        }
        return result
    }

    static func ownedGames(_ id: String, key: String) async throws -> [OwnedGame] {
        let json = try await fetchJSON(api + "IPlayerService/GetOwnedGames/v1/", [
            "key": key, "steamid": id, "include_appinfo": "1", "include_played_free_games": "1"
        ])
        guard let response = json["response"] as? [String: Any], let games = response["games"] else {
            throw SteamError.privateProfile
        }
        return decode([OwnedGame].self, games) ?? []
    }

    static func level(_ id: String, key: String) async -> Int? {
        let json = try? await fetchJSON(api + "IPlayerService/GetSteamLevel/v1/", ["key": key, "steamid": id])
        return (json?["response"] as? [String: Any])?["player_level"] as? Int
    }

    static func friends(_ id: String, key: String) async throws -> [Player] {
        let json = try await fetchJSON(api + "ISteamUser/GetFriendList/v1/", ["key": key, "steamid": id, "relationship": "friend"])
        guard let list = (json["friendslist"] as? [String: Any])?["friends"] as? [[String: Any]] else {
            throw SteamError.privateProfile
        }
        let ids = list.compactMap { $0["steamid"] as? String }
        return try await players(ids, key: key)
    }

    static func achievements(_ appid: Int, steamID: String, key: String) async throws -> [Achievement] {
        async let schemaJSON = fetchJSON(api + "ISteamUserStats/GetSchemaForGame/v2/", ["key": key, "appid": String(appid), "l": "english"])
        async let playerJSON = try? fetchJSON(api + "ISteamUserStats/GetPlayerAchievements/v1/", ["key": key, "steamid": steamID, "appid": String(appid), "l": "english"])
        async let globalJSON = try? fetchJSON(api + "ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/", ["gameid": String(appid)])

        let schema = try await schemaJSON
        let definitions = ((schema["game"] as? [String: Any])?["availableGameStats"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []
        var mine: [String: (Bool, Double)] = [:]
        if let list = ((await playerJSON)?["playerstats"] as? [String: Any])?["achievements"] as? [[String: Any]] {
            for item in list {
                guard let name = item["apiname"] as? String else { continue }
                mine[name] = (((item["achieved"] as? Int) ?? 0) == 1, (item["unlocktime"] as? Double) ?? 0)
            }
        }
        var global: [String: Double] = [:]
        if let list = ((await globalJSON)?["achievementpercentages"] as? [String: Any])?["achievements"] as? [[String: Any]] {
            for item in list {
                guard let name = item["name"] as? String else { continue }
                if let value = item["percent"] as? Double { global[name] = value }
                else if let text = item["percent"] as? String, let value = Double(text) { global[name] = value }
            }
        }
        return definitions.compactMap { def in
            guard let name = def["name"] as? String else { return nil }
            let state = mine[name]
            return Achievement(
                apiName: name,
                title: def["displayName"] as? String ?? name,
                detail: def["description"] as? String ?? "",
                icon: (def["icon"] as? String).flatMap(URL.init(string:)),
                iconGray: (def["icongray"] as? String).flatMap(URL.init(string:)),
                achieved: state?.0 ?? false,
                unlocked: (state?.1 ?? 0) > 0 ? Date(timeIntervalSince1970: state!.1) : nil,
                globalPercent: global[name],
                hidden: ((def["hidden"] as? Int) ?? 0) == 1
            )
        }
    }

    static func wishlist(_ id: String, key: String) async throws -> [WishlistEntry] {
        let json = try await fetchJSON(api + "IWishlistService/GetWishlist/v1/", ["key": key, "steamid": id])
        let items = (json["response"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let appid = item["appid"] as? Int else { return nil }
            let added = (item["date_added"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return WishlistEntry(appid: appid, priority: (item["priority"] as? Int) ?? 0, added: added)
        }
    }

    /// UK store prices for many apps at once.
    static func prices(_ appids: [Int], country: String = "gb") async -> [Int: StorePrice?] {
        var result: [Int: StorePrice?] = [:]
        for chunk in stride(from: 0, to: appids.count, by: 50).map({ Array(appids[$0..<min($0 + 50, appids.count)]) }) {
            guard let json = try? await fetchJSON("https://store.steampowered.com/api/appdetails", [
                "appids": chunk.map(String.init).joined(separator: ","), "cc": country, "filters": "price_overview"
            ]) else { continue }
            for appid in chunk {
                guard let entry = json[String(appid)] as? [String: Any], (entry["success"] as? Bool) == true else { continue }
                let data = entry["data"] as? [String: Any]
                result[appid] = decode(StorePrice.self, data?["price_overview"])
            }
        }
        return result
    }

    /// The store name for an app (the wishlist API only gives IDs).
    static func name(_ appid: Int) async -> String? {
        guard let json = try? await fetchJSON("https://store.steampowered.com/api/appdetails", ["appids": String(appid), "filters": "basic"]),
              let entry = json[String(appid)] as? [String: Any],
              let data = entry["data"] as? [String: Any] else { return nil }
        return data["name"] as? String
    }
}

// MARK: Images

actor ImageCache {
    static let shared = ImageCache()
    private var cache: [URL: UIImage] = [:]
    private var order: [URL] = []

    func image(_ url: URL) async -> UIImage? {
        if let hit = cache[url] { return hit }
        guard let result = try? await Steam.session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: result.0)?.preparingForDisplay() else { return nil }
        cache[url] = image
        order.append(url)
        if order.count > 400 { cache[order.removeFirst()] = nil }
        return image
    }
}

// MARK: Keychain

enum Keychain {
    private static let service = "app.keepwatch.hoard"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
