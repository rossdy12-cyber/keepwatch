import BackgroundTasks
import SwiftUI
import UserNotifications

struct WatchItem: Codable, Identifiable, Hashable {
    let gameID: String
    var title: String
    var steamAppID: String?
    var thumb: String?
    /// Target price in US dollars (CheapShark's currency).
    var target: Double
    var lastPrice: Double?
    var lastStoreID: String?
    var lastDealID: String?
    var notifiedPrice: Double?
    var id: String { gameID }
    var isHit: Bool { (lastPrice ?? .infinity) <= target }
}

enum Currency: String, CaseIterable, Identifiable {
    case GBP, EUR, USD
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .GBP: return "£"
        case .EUR: return "€"
        case .USD: return "$"
        }
    }
}

@MainActor
final class TitheStore: ObservableObject {
    static let refreshID = "app.keepwatch.tithe.refresh"

    @Published private(set) var stores: [Store] = []
    @Published private(set) var rates: [String: Double] = [:]
    @Published var currency: Currency {
        didSet { UserDefaults.standard.set(currency.rawValue, forKey: "tithe.currency") }
    }
    @Published private(set) var watchlist: [WatchItem] = []
    @Published var notificationsAllowed = false
    @Published var errorMessage: String?

    init() {
        currency = Currency(rawValue: UserDefaults.standard.string(forKey: "tithe.currency") ?? "") ?? .GBP
        watchlist = Self.loadWatchlist()
    }

    // MARK: Setup

    func start() async {
        async let storeList = try? DealsAPI.stores()
        async let fx = DealsAPI.usdRates()
        if let list = await storeList { stores = list.filter { $0.isActive == 1 } }
        let fetched = await fx
        if !fetched.isEmpty { rates = fetched }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
        await refreshWatchlist(notify: false)
        Self.scheduleRefresh()
    }

    func store(_ id: String) -> Store? { stores.first { $0.storeID == id } }

    // MARK: Prices

    /// Formats a US-dollar price in the chosen currency. Converted prices are estimates.
    func price(_ usd: Double) -> String {
        if usd == 0 { return "Free" }
        let rate = currency == .USD ? 1 : (rates[currency.rawValue] ?? 0)
        guard rate > 0 else { return String(format: "$%.2f", usd) }
        let value = usd * rate
        return (currency == .USD ? "" : "~") + currency.symbol + String(format: "%.2f", value)
    }

    func usd(fromLocal value: Double) -> Double {
        let rate = currency == .USD ? 1 : (rates[currency.rawValue] ?? 1)
        return rate > 0 ? value / rate : value
    }

    func local(fromUSD value: Double) -> Double {
        let rate = currency == .USD ? 1 : (rates[currency.rawValue] ?? 1)
        return value * rate
    }

    // MARK: Watchlist

    func isWatched(_ gameID: String) -> Bool { watchlist.contains { $0.gameID == gameID } }

    func watch(gameID: String, title: String, steamAppID: String?, thumb: String?, targetUSD: Double, currentUSD: Double?) {
        watchlist.removeAll { $0.gameID == gameID }
        watchlist.insert(WatchItem(gameID: gameID, title: title, steamAppID: steamAppID, thumb: thumb, target: targetUSD, lastPrice: currentUSD), at: 0)
        save()
        Task { await requestNotifications() }
    }

    func unwatch(_ gameID: String) {
        watchlist.removeAll { $0.gameID == gameID }
        save()
    }

    func setTarget(_ gameID: String, usd: Double) {
        guard let index = watchlist.firstIndex(where: { $0.gameID == gameID }) else { return }
        watchlist[index].target = usd
        watchlist[index].notifiedPrice = nil
        save()
    }

    func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationsAllowed = granted
    }

    /// Fetches current prices; when one reaches its target (and hasn't been announced at that
    /// price already), posts a local notification.
    func refreshWatchlist(notify: Bool = true) async {
        guard !watchlist.isEmpty else { return }
        do {
            let details = try await DealsAPI.games(watchlist.map(\.gameID))
            var announcements: [WatchItem] = []
            for index in watchlist.indices {
                guard let detail = details[watchlist[index].gameID] else { continue }
                let best = detail.deals.min { $0.priceValue < $1.priceValue }
                watchlist[index].lastPrice = best?.priceValue
                watchlist[index].lastStoreID = best?.storeID
                watchlist[index].lastDealID = best?.dealID
                if let thumb = detail.info.thumb { watchlist[index].thumb = thumb }
                let item = watchlist[index]
                if item.isHit, let price = item.lastPrice, item.notifiedPrice.map({ price < $0 }) ?? true {
                    announcements.append(item)
                    watchlist[index].notifiedPrice = price
                } else if !item.isHit {
                    watchlist[index].notifiedPrice = nil
                }
            }
            save()
            if notify { announce(announcements) }
            updateBadge()
        } catch {
            if notify == false { errorMessage = error.localizedDescription }
        }
    }

    private func announce(_ items: [WatchItem]) {
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = "\(item.title) has fallen"
            let storeName = item.lastStoreID.flatMap { store($0)?.storeName } ?? "a store"
            content.body = "\(price(item.lastPrice ?? 0)) at \(storeName), at or below your \(price(item.target)) target."
            content.sound = .default
            content.userInfo = ["gameID": item.gameID]
            let request = UNNotificationRequest(identifier: "tithe-\(item.gameID)-\(item.lastPrice ?? 0)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(watchlist.filter(\.isHit).count) { _ in }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(watchlist) {
            UserDefaults.standard.set(data, forKey: "tithe.watchlist")
        }
    }

    nonisolated static func loadWatchlist() -> [WatchItem] {
        guard let data = UserDefaults.standard.data(forKey: "tithe.watchlist") else { return [] }
        return (try? JSONDecoder().decode([WatchItem].self, from: data)) ?? []
    }

    // MARK: Background

    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

extension TitheStore {
    /// Runs when iOS wakes the app in the background.
    nonisolated static func backgroundCheck() async {
        let store = await TitheStore()
        await store.loadRatesQuietly()
        await store.refreshWatchlist(notify: true)
    }

    func loadRatesQuietly() async {
        let fetched = await DealsAPI.usdRates()
        if !fetched.isEmpty { rates = fetched }
        stores = (try? await DealsAPI.stores())?.filter { $0.isActive == 1 } ?? []
    }
}
