import Foundation

// MARK: Models (CheapShark sends most numbers as strings)

struct Deal: Decodable, Identifiable, Hashable {
    let dealID: String
    let title: String
    let storeID: String
    let gameID: String
    let salePrice: String
    let normalPrice: String
    let savings: String
    let metacriticScore: String?
    let steamRatingText: String?
    let steamRatingPercent: String?
    let steamAppID: String?
    let releaseDate: Double?
    let dealRating: String?
    let thumb: String?

    var id: String { dealID }
    var sale: Double { Double(salePrice) ?? 0 }
    var normal: Double { Double(normalPrice) ?? 0 }
    var percentOff: Int { Int((Double(savings) ?? 0).rounded()) }
    var rating: Double { Double(dealRating ?? "") ?? 0 }
    var metacritic: Int? { Int(metacriticScore ?? "").flatMap { $0 > 0 ? $0 : nil } }
    var steamPercent: Int? { Int(steamRatingPercent ?? "").flatMap { $0 > 0 ? $0 : nil } }
}

struct GameSearchResult: Decodable, Identifiable, Hashable {
    let gameID: String
    let steamAppID: String?
    let cheapest: String
    let external: String
    let thumb: String?
    var id: String { gameID }
}

struct GameDetail: Decodable {
    struct Info: Decodable {
        let title: String
        let steamAppID: String?
        let thumb: String?
    }
    struct Cheapest: Decodable {
        let price: String
        let date: Double
    }
    struct StoreDeal: Decodable, Identifiable {
        let storeID: String
        let dealID: String
        let price: String
        let retailPrice: String
        let savings: String
        var id: String { dealID }
        var priceValue: Double { Double(price) ?? 0 }
        var percentOff: Int { Int((Double(savings) ?? 0).rounded()) }
    }
    let info: Info
    let cheapestPriceEver: Cheapest?
    let deals: [StoreDeal]
}

struct Store: Decodable, Identifiable, Hashable {
    let storeID: String
    let storeName: String
    let isActive: Int
    var id: String { storeID }
    /// CheapShark's store images are numbered from 0.
    var iconURL: URL? { URL(string: "https://www.cheapshark.com/img/stores/icons/\((Int(storeID) ?? 1) - 1).png") }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case rating = "Deal Rating"
    case savings = "Savings"
    case price = "Price"
    case recent = "Recent"
    case metacritic = "Metacritic"
    case reviews = "Reviews"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rating: return "Best deals"
        case .savings: return "Biggest discount"
        case .price: return "Cheapest"
        case .recent: return "Newest deals"
        case .metacritic: return "Metacritic score"
        case .reviews: return "Steam reviews"
        }
    }
}

// MARK: API

enum DealsAPI {
    private static let base = "https://www.cheapshark.com/api/1.0/"
    /// CheapShark asks clients to identify themselves.
    private static let userAgent = "Tithe/1.0 (personal iOS game-deals app)"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        return URLSession(configuration: config)
    }()

    static var imageSession: URLSession { session }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> (T, HTTPURLResponse?) {
        var components = URLComponents(string: base + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 429 {
            throw NSError(domain: "Tithe", code: 429, userInfo: [NSLocalizedDescriptionKey: "CheapShark asked us to slow down. Try again in a minute."])
        }
        return (try JSONDecoder().decode(T.self, from: data), http)
    }

    static func deals(page: Int, sort: SortOrder, stores: Set<String>, maxPrice: Int?, onlyAAA: Bool, title: String?) async throws -> (deals: [Deal], pages: Int) {
        var query = ["pageNumber": String(page), "pageSize": "40", "sortBy": sort.rawValue, "onSale": "1"]
        if !stores.isEmpty { query["storeID"] = stores.sorted().joined(separator: ",") }
        if let maxPrice { query["upperPrice"] = String(maxPrice) }
        if onlyAAA { query["AAA"] = "1" }
        if let title, !title.isEmpty { query["title"] = title }
        if sort == .price { query["desc"] = "0" }
        let (deals, response): ([Deal], HTTPURLResponse?) = try await get("deals", query)
        let pages = Int(response?.value(forHTTPHeaderField: "X-Total-Page-Count") ?? "") ?? 1
        return (deals, pages)
    }

    static func search(_ title: String) async throws -> [GameSearchResult] {
        let (results, _): ([GameSearchResult], HTTPURLResponse?) = try await get("games", ["title": title, "limit": "60"])
        return results
    }

    static func game(_ id: String) async throws -> GameDetail {
        let (detail, _): (GameDetail, HTTPURLResponse?) = try await get("games", ["id": id])
        return detail
    }

    /// Several games at once (used for the watchlist), keyed by game ID.
    static func games(_ ids: [String]) async throws -> [String: GameDetail] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: GameDetail] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 25).map({ Array(ids[$0..<min($0 + 25, ids.count)]) }) {
            let (part, _): ([String: GameDetail], HTTPURLResponse?) = try await get("games", ["ids": chunk.joined(separator: ",")])
            result.merge(part) { a, _ in a }
        }
        return result
    }

    static func stores() async throws -> [Store] {
        let (stores, _): ([Store], HTTPURLResponse?) = try await get("stores", [:])
        return stores
    }

    static func redirect(_ dealID: String) -> URL {
        // dealIDs arrive already percent-encoded.
        URL(string: "https://www.cheapshark.com/redirect?dealID=\(dealID)")!
    }

    static func steamHeader(_ appID: String?) -> URL? {
        guard let appID, !appID.isEmpty else { return nil }
        return URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/header.jpg")
    }

    static func usdRates() async -> [String: Double] {
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?from=USD&to=GBP,EUR"),
              let result = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let rates = json["rates"] as? [String: Double] else { return [:] }
        return rates
    }
}
