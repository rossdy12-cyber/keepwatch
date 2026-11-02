import Foundation

// MARK: - Lauren & Ross Gothic Handover Schedule

struct HandoverItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    var targetDay: String
    var targetTime: String
    var completed: Bool = false
}

// MARK: - Spooky / Gamer Night Picker

struct NightPickItem: Codable, Identifiable, Equatable {
    enum Category: String, Codable, CaseIterable {
        case game = "Game"
        case movie = "Horror Movie"
    }
    var id = UUID()
    var title: String
    var subtitle: String
    var category: Category
    var watchedOrPlayed: Bool = false
}

// MARK: - WooCommerce Store Admin

struct WooStoreConfig: Codable, Equatable {
    var siteURL: String = ""
    var consumerKey: String = ""
    var consumerSecret: String = ""

    var baseURL: String {
        ServerAddress.normalize(siteURL, defaultScheme: "https")
    }

    var isConfigured: Bool {
        !baseURL.isEmpty && !consumerKey.isEmpty && !consumerSecret.isEmpty
    }
}

struct WooProduct: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var sku: String?
    var status: String // "publish", "private", "draft", "pending"
    var price: String
    var regular_price: String?
    var stock_status: String // "instock", "outofstock"
    var stock_quantity: Int?
    var permalink: String?
}

struct WooOrderBilling: Codable, Equatable {
    var first_name: String?
    var last_name: String?
    var email: String?

    var fullName: String {
        let joined = [first_name ?? "", last_name ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "Guest Customer" : joined
    }
}

struct WooOrderLineItem: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var quantity: Int
    var total: String
}

struct WooOrder: Codable, Identifiable, Equatable {
    var id: Int
    var number: String
    var status: String
    var total: String
    var currency_symbol: String?
    var date_created: String
    var billing: WooOrderBilling?
    var line_items: [WooOrderLineItem]?
}

struct WooTotalEntry: Codable, Equatable {
    var slug: String
    var name: String
    var total: Int
}

@MainActor
final class HubStore: ObservableObject {
    static let shared = HubStore()

    private static let handoverKey = "hub.handover"
    private static let picksKey = "hub.picks"
    private static let storeConfigKey = "hub.woostore"

    @Published var handoverItems: [HandoverItem] {
        didSet {
            if let data = try? JSONEncoder().encode(handoverItems) {
                UserDefaults.standard.set(data, forKey: Self.handoverKey)
            }
        }
    }

    @Published var picks: [NightPickItem] {
        didSet {
            if let data = try? JSONEncoder().encode(picks) {
                UserDefaults.standard.set(data, forKey: Self.picksKey)
            }
        }
    }

    @Published var wooConfig: WooStoreConfig {
        didSet {
            Keychain.save(wooConfig, for: Self.storeConfigKey)
        }
    }

    @Published private(set) var products: [WooProduct] = []
    @Published private(set) var orders: [WooOrder] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isLoadingOrders = false
    @Published var mirrorComparison: String?
    @Published var storeError: String?
    @Published var radarrStatus: String?

    init() {
        let defaults = UserDefaults.standard
        handoverItems = defaults.data(forKey: Self.handoverKey).flatMap { try? JSONDecoder().decode([HandoverItem].self, from: $0) }
            ?? Self.defaultHandoverItems
        picks = defaults.data(forKey: Self.picksKey).flatMap { try? JSONDecoder().decode([NightPickItem].self, from: $0) }
            ?? Self.defaultPicks
        wooConfig = Keychain.load(WooStoreConfig.self, for: Self.storeConfigKey) ?? WooStoreConfig()
    }

    func resetHandover() {
        handoverItems = Self.defaultHandoverItems
    }

    static let defaultHandoverItems: [HandoverItem] = [
        HandoverItem(
            title: "Lauren and Ross Extra Notes",
            detail: "Including any evidence",
            targetDay: "Monday",
            targetTime: "10:00 PM"
        ),
        HandoverItem(
            title: "Halloween Questions for Ross",
            detail: "Written responses to all 9 Halloween weekend questions",
            targetDay: "Tuesday",
            targetTime: "9:00 PM"
        ),
        HandoverItem(
            title: "Notes for Lauren regarding Past Issues",
            detail: "Evidence Required",
            targetDay: "Tuesday",
            targetTime: "11:00 PM"
        ),
        HandoverItem(
            title: "Relationship Fixing Questions for Ross",
            detail: "Written responses to all 8 relationship fixing questions",
            targetDay: "Wednesday",
            targetTime: "11:00 PM"
        )
    ]

    static let defaultPicks: [NightPickItem] = [
        NightPickItem(title: "The Outlast Trials", subtitle: "Co-op survival horror · PC", category: .game),
        NightPickItem(title: "Phasmophobia", subtitle: "Co-op ghost hunting · Steam", category: .game),
        NightPickItem(title: "Little Nightmares II", subtitle: "Spooky atmospheric platformer", category: .game),
        NightPickItem(title: "Until Dawn / The Quarry", subtitle: "Pass-the-controller interactive horror", category: .game),
        NightPickItem(title: "Dead by Daylight", subtitle: "Asymmetrical horror · PC/PS4", category: .game),
        NightPickItem(title: "Aniimo", subtitle: "Cozy loft & base building", category: .game),
        NightPickItem(title: "Sinister (2012)", subtitle: "High jumpscare rating · Super 8 tapes", category: .movie),
        NightPickItem(title: "The Autopsy of Jane Doe (2016)", subtitle: "Claustrophobic morgue mystery", category: .movie),
        NightPickItem(title: "Talk to Me (2022)", subtitle: "Modern supernatural horror", category: .movie),
        NightPickItem(title: "Smile 2 (2024)", subtitle: "Relentless jumpscares", category: .movie),
        NightPickItem(title: "The Conjuring (2013)", subtitle: "Classic haunted house jumpscares", category: .movie),
        NightPickItem(title: "Evil Dead Rise (2023)", subtitle: "Intense apartment possession horror", category: .movie),
        NightPickItem(title: "Insidious (2010)", subtitle: "Astral projection & The Further", category: .movie)
    ]

    // MARK: - Radarr Quick-Add for Horror Movies

    func sendMovieToRadarr(title: String, radarrConfig: ServiceConfig) async {
        guard radarrConfig.isConfigured else {
            radarrStatus = "Set up Radarr in Settings first."
            return
        }
        radarrStatus = "Searching Radarr for \"\(title)\"…"
        do {
            let cleanTitle = title.replacingOccurrences(of: "\\s*\\(\\d{4}\\)", with: "", options: .regularExpression)
            guard let lookupURL = makeURL(base: radarrConfig.baseURL, path: "/api/v3/movie/lookup", query: [
                URLQueryItem(name: "term", value: cleanTitle)
            ]) else {
                radarrStatus = "Invalid Radarr URL."
                return
            }
            var lookupReq = URLRequest(url: lookupURL)
            lookupReq.setValue(radarrConfig.apiKey, forHTTPHeaderField: "X-Api-Key")
            let results = try await fetchJSON(lookupReq, service: "Radarr").array
            guard let first = results.first, let tmdbId = first["tmdbId"].int else {
                radarrStatus = "No match found in Radarr for \(cleanTitle)."
                return
            }
            let movieTitle = first["title"].string ?? cleanTitle
            if first["id"].int != nil && (first["id"].int ?? 0) > 0 {
                radarrStatus = "✓ \"\(movieTitle)\" is already in your Radarr library!"
                return
            }

            guard let rootURL = makeURL(base: radarrConfig.baseURL, path: "/api/v3/rootfolder"),
                  let profURL = makeURL(base: radarrConfig.baseURL, path: "/api/v3/qualityprofile") else { return }
            var rootReq = URLRequest(url: rootURL)
            rootReq.setValue(radarrConfig.apiKey, forHTTPHeaderField: "X-Api-Key")
            var profReq = URLRequest(url: profURL)
            profReq.setValue(radarrConfig.apiKey, forHTTPHeaderField: "X-Api-Key")

            let roots = try await fetchJSON(rootReq, service: "Radarr").array
            let profiles = try await fetchJSON(profReq, service: "Radarr").array
            guard let rootPath = roots.first?["path"].string,
                  let profileId = profiles.first?["id"].int else {
                radarrStatus = "Couldn't read Radarr root folder or quality profile."
                return
            }

            guard let addURL = makeURL(base: radarrConfig.baseURL, path: "/api/v3/movie") else { return }
            var addReq = URLRequest(url: addURL)
            addReq.httpMethod = "POST"
            addReq.setValue(radarrConfig.apiKey, forHTTPHeaderField: "X-Api-Key")
            addReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "title": movieTitle,
                "tmdbId": tmdbId,
                "qualityProfileId": profileId,
                "rootFolderPath": rootPath,
                "monitored": true,
                "addOptions": ["searchForMovie": true]
            ]
            addReq.httpBody = try JSONSerialization.data(withJSONObject: body)
            _ = try await fetchJSON(addReq, service: "Radarr")
            radarrStatus = "✓ Added \"\(movieTitle)\" to Radarr & started search!"
        } catch {
            radarrStatus = "Radarr: \(describe(error))"
        }
    }

    // MARK: - WooCommerce REST API (#4 Racebolt UK Pocket Manager)

    private var authQuery: [URLQueryItem] {
        [
            URLQueryItem(name: "consumer_key", value: wooConfig.consumerKey),
            URLQueryItem(name: "consumer_secret", value: wooConfig.consumerSecret)
        ]
    }

    func fetchProducts(search: String = "") async {
        guard wooConfig.isConfigured else { return }
        isLoadingProducts = true
        storeError = nil
        defer { isLoadingProducts = false }
        do {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "per_page", value: "40"),
                URLQueryItem(name: "status", value: "any")
            ] + authQuery
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                query.append(URLQueryItem(name: "search", value: trimmed))
            }
            guard let url = makeURL(base: wooConfig.baseURL, path: "/wp-json/wc/v3/products", query: query) else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.server("No response from store.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized("WooCommerce")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode)
            }
            products = try JSONDecoder().decode([WooProduct].self, from: data)
        } catch {
            if !isCancellation(error) {
                storeError = describe(error)
            }
        }
    }

    func updateProductStatus(_ product: WooProduct, newStatus: String) async {
        await updateProductFields(product, body: ["status": newStatus])
    }

    func updateProductStockAndPrice(_ product: WooProduct, price: String, stockQuantity: Int?) async {
        var body: [String: Any] = ["regular_price": price]
        if let qty = stockQuantity {
            body["manage_stock"] = true
            body["stock_quantity"] = qty
            body["stock_status"] = qty > 0 ? "instock" : "outofstock"
        }
        await updateProductFields(product, body: body)
    }

    private func updateProductFields(_ product: WooProduct, body: [String: Any]) async {
        guard wooConfig.isConfigured else { return }
        guard let url = makeURL(base: wooConfig.baseURL, path: "/wp-json/wc/v3/products/\(product.id)", query: authQuery) else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await httpSession.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let updated = try? JSONDecoder().decode(WooProduct.self, from: data),
               let idx = products.firstIndex(where: { $0.id == product.id }) {
                products[idx] = updated
            }
        } catch {
            storeError = describe(error)
        }
    }

    func fetchOrders() async {
        guard wooConfig.isConfigured else { return }
        isLoadingOrders = true
        storeError = nil
        defer { isLoadingOrders = false }
        do {
            let query = [URLQueryItem(name: "per_page", value: "25")] + authQuery
            guard let url = makeURL(base: wooConfig.baseURL, path: "/wp-json/wc/v3/orders", query: query) else { return }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            orders = try JSONDecoder().decode([WooOrder].self, from: data)
        } catch {
            if !isCancellation(error) {
                storeError = describe(error)
            }
        }
    }

    func updateOrderStatus(_ order: WooOrder, newStatus: String) async {
        guard wooConfig.isConfigured else { return }
        guard let url = makeURL(base: wooConfig.baseURL, path: "/wp-json/wc/v3/orders/\(order.id)", query: authQuery) else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["status": newStatus])
        do {
            let (data, response) = try await httpSession.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let updated = try? JSONDecoder().decode(WooOrder.self, from: data),
               let idx = orders.firstIndex(where: { $0.id == order.id }) {
                orders[idx] = updated
            }
        } catch {
            storeError = describe(error)
        }
    }

    func compareLiveAndNASMirror() async {
        guard wooConfig.isConfigured else { return }
        mirrorComparison = "Checking raceboltuk.com vs raceboltuk.nas-server.co.uk…"
        async let liveTotals = fetchProductTotals(base: "https://raceboltuk.com")
        async let nasTotals = fetchProductTotals(base: "https://raceboltuk.nas-server.co.uk")
        let (live, nas) = await (liveTotals, nasTotals)
        mirrorComparison = "Live (raceboltuk.com): \(live) published · TrueNAS Mirror: \(nas) published"
    }

    private func fetchProductTotals(base: String) async -> Int {
        guard let url = makeURL(base: base, path: "/wp-json/wc/v3/reports/products/totals", query: authQuery) else { return 0 }
        do {
            let (data, _) = try await httpSession.data(from: url)
            let decoded = try JSONDecoder().decode([WooTotalEntry].self, from: data)
            return decoded.first(where: { $0.slug == "publish" })?.total ?? decoded.reduce(0) { $0 + $1.total }
        } catch {
            return 0
        }
    }
}
