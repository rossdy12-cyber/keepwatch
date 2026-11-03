import Foundation

struct PaydaysConfig: Codable, Equatable {
    var address: String = "https://paydays.nas-server.co.uk"
    var password: String = ""
    /// Optional full `/hook/spend?token=...` URL or token so Siri / Action Button can log spending even behind Authelia.
    var hookURLOrToken: String = ""
    var acceptSelfSigned: Bool = true

    var baseURL: String {
        ServerAddress.normalize(address, defaultScheme: "http")
    }

    var isConfigured: Bool {
        !baseURL.isEmpty || !hookURLOrToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct PaydaysBill: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var amount: Int // pence
    var day: Int
    var category: String
    var active: Int

    var isActive: Bool { active != 0 }
}

struct PaydaysEntry: Codable, Identifiable, Equatable {
    var id: Int
    var date: String
    var amount: Int // pence
    var kind: String // "pay", "spend", "extra"
    var note: String
    var source: String?
    var created: Double?
}

struct PaydaysPaid: Codable, Equatable {
    var bill_id: Int
    var month: String
}

struct PaydaysServerSettings: Codable, Equatable {
    var pay_amount: Int
    var pay_frequency: String
    var pay_anchor: String
    var currency: String
    var savings: Int
    var hook_token: String?
    var ntfy_server: String?
    var ntfy_topic: String?
    var alert_over: Bool?
    var alert_pace: Bool?
    var alert_big: Int?
}

struct PaydaysSnapshot: Codable, Equatable {
    var bills: [PaydaysBill] = []
    var pays: [PaydaysEntry] = []
    var paid: [PaydaysPaid] = []
    var months: [String: Int] = [:]
    var settings: PaydaysServerSettings = PaydaysServerSettings(
        pay_amount: 0, pay_frequency: "weekly", pay_anchor: "", currency: "GBP", savings: 0
    )
}

struct PaydaysSummary: Equatable {
    var safePerWeekPence: Int
    var safePerDayPence: Int
    var allowancePence: Int
    var spentPence: Int
    var leftPence: Int
    var perDayLeftPence: Int
    var daysLeft: Int
    var periodDays: Int
    var nextPaydayLabel: String
    var periodStart: String
    var periodEnd: String
}

@MainActor
final class PaydaysStore: ObservableObject {
    static let shared = PaydaysStore()

    private static let configKey = "paydays.config"
    private static let cacheKey = "paydays.snapshot"

    @Published var config: PaydaysConfig {
        didSet {
            Keychain.save(config, for: Self.configKey)
            applyTrust()
        }
    }

    @Published private(set) var snapshot: PaydaysSnapshot?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var lastHookMessage: String?

    init() {
        config = Keychain.load(PaydaysConfig.self, for: Self.configKey) ?? PaydaysConfig()
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(PaydaysSnapshot.self, from: data) {
            snapshot = cached
        }
        applyTrust()
    }

    private func applyTrust() {
        if let host = URL(string: config.baseURL)?.host {
            TrustDelegate.shared.setTrusted(host: host, trusted: config.acceptSelfSigned)
        }
    }

    static func formatPence(_ pence: Int) -> String {
        let sign = pence < 0 ? "-" : ""
        let pounds = Double(abs(pence)) / 100.0
        return String(format: "%@£%.2f", sign, pounds)
    }

    // MARK: - API Calls

    private func makeRequest(path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        let base = config.baseURL
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.password.isEmpty {
            let auth = Data((":" + config.password).utf8).base64EncodedString()
            request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func refresh() async {
        guard !config.baseURL.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let request = try makeRequest(path: "/api/data")
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.server("No response from Paydays.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized("Paydays")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode)
            }
            let decoded = try JSONDecoder().decode(PaydaysSnapshot.self, from: data)
            saveSnapshot(decoded)
        } catch {
            if !isCancellation(error) {
                errorMessage = describe(error)
            }
        }
    }

    private func saveSnapshot(_ decoded: PaydaysSnapshot) {
        snapshot = decoded
        if let encoded = try? JSONEncoder().encode(decoded) {
            UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
        }
        if let token = decoded.settings.hook_token, !token.isEmpty, config.hookURLOrToken.isEmpty {
            config.hookURLOrToken = token
        }
    }

    /// Logs a spend entry using `/api/spend` first, or falls back to `/hook/spend?token=...` if configured.
    func logSpend(amountPounds: Double, merchant: String, dateString: String? = nil) async throws -> String {
        let pence = Int((amountPounds * 100.0).rounded())
        guard pence > 0 else {
            throw APIError.server("Enter an amount greater than £0.00.")
        }
        let cleanNote = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = dateString ?? Self.todayISO()

        // Try /api/spend if baseURL is configured
        if !config.baseURL.isEmpty {
            do {
                let req = try makeRequest(path: "/api/spend", method: "POST", body: [
                    "date": day,
                    "amount": pence,
                    "note": cleanNote.isEmpty ? "Spending" : cleanNote
                ])
                let (data, response) = try await httpSession.data(for: req)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let decoded = try? JSONDecoder().decode(PaydaysSnapshot.self, from: data) {
                    saveSnapshot(decoded)
                    let msg = statusLine()
                    lastHookMessage = msg
                    return "\(cleanNote.isEmpty ? "Logged" : cleanNote) \(Self.formatPence(pence)). \(msg)"
                }
            } catch {
                // Fall through to hook URL if available
                if hookEndpointURL() == nil { throw error }
            }
        }

        // Fallback: /hook/spend?token=... (works even behind Authelia bypass or from Siri background)
        if let hookURL = hookEndpointURL() {
            var request = URLRequest(url: hookURL, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "amount": String(format: "%.2f", amountPounds),
                "merchant": cleanNote.isEmpty ? "Apple Pay" : cleanNote
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let text = String(decoding: data, as: UTF8.self)
                throw APIError.server(text.isEmpty ? "Paydays hook failed." : text)
            }
            let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lastHookMessage = reply
            Task { await refresh() }
            return reply
        }

        throw APIError.notConfigured("Paydays")
    }

    func deleteSpend(id: Int) async {
        guard let req = try? makeRequest(path: "/api/spend/\(id)", method: "DELETE") else { return }
        if let (data, response) = try? await httpSession.data(for: req),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(PaydaysSnapshot.self, from: data) {
            saveSnapshot(decoded)
        }
    }

    func toggleBillPaid(bill: PaydaysBill, month: String) async {
        let currentlyPaid = isBillPaid(billID: bill.id, month: month)
        guard let req = try? makeRequest(path: "/api/paid", method: "PUT", body: [
            "bill_id": bill.id,
            "month": month,
            "paid": !currentlyPaid
        ]) else { return }
        if let (data, response) = try? await httpSession.data(for: req),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(PaydaysSnapshot.self, from: data) {
            saveSnapshot(decoded)
        }
    }

    func addBill(name: String, amountPounds: Double, day: Int, category: String) async throws {
        let pence = Int((amountPounds * 100.0).rounded())
        let req = try makeRequest(path: "/api/bills", method: "POST", body: [
            "name": name,
            "amount": pence,
            "day": day,
            "category": category
        ])
        let (data, response) = try await httpSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("Couldn't add the bill.")
        }
        let decoded = try JSONDecoder().decode(PaydaysSnapshot.self, from: data)
        saveSnapshot(decoded)
    }

    func isBillPaid(billID: Int, month: String) -> Bool {
        snapshot?.paid.contains(where: { $0.bill_id == billID && $0.month == month }) ?? false
    }

    private func hookEndpointURL() -> URL? {
        let raw = config.hookURLOrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return URL(string: raw)
        }
        let token = raw.isEmpty ? (snapshot?.settings.hook_token ?? "") : raw
        guard !token.isEmpty, !config.baseURL.isEmpty else { return nil }
        return makeURL(base: config.baseURL, path: "/hook/spend", query: [URLQueryItem(name: "token", value: token)])
    }

    // MARK: - Budget Math (Mirrors paydays/server.py)

    static func todayISO() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func currentMonthISO() -> String {
        String(todayISO().prefix(7))
    }

    var summary: PaydaysSummary? {
        guard let snap = snapshot else { return nil }
        let s = snap.settings
        guard s.pay_amount > 0, !s.pay_anchor.isEmpty else { return nil }

        let paysPerYear: Double
        switch s.pay_frequency {
        case "weekly": paysPerYear = 365.25 / 7.0
        case "fortnightly": paysPerYear = 365.25 / 14.0
        case "fourweekly": paysPerYear = 365.25 / 28.0
        case "monthly": paysPerYear = 12.0
        default: paysPerYear = 365.25 / 7.0
        }

        let yearlyPay = Double(s.pay_amount) * paysPerYear
        let monthlyBills = snap.bills.filter(\.isActive).reduce(0) { $0 + $1.amount }
        let yearlyOut = Double(monthlyBills + s.savings) * 12.0
        let safePerWeek = max(0, Int(((yearlyPay - yearlyOut) / (365.25 / 7.0)).rounded()))
        let safePerDay = safePerWeek / 7

        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd"

        guard let anchorDate = f.date(from: s.pay_anchor),
              let todayDate = f.date(from: Self.todayISO()) else { return nil }

        let stepDays: Int
        switch s.pay_frequency {
        case "fortnightly": stepDays = 14
        case "fourweekly": stepDays = 28
        default: stepDays = 7
        }

        var startPay = anchorDate
        var nextPay = anchorDate
        if s.pay_frequency == "monthly" {
            let anchorDay = cal.component(.day, from: anchorDate)
            var comps = cal.dateComponents([.year, .month], from: todayDate)
            comps.day = min(anchorDay, 28)
            let candidate = cal.date(from: comps) ?? todayDate
            if candidate <= todayDate {
                startPay = candidate
                nextPay = cal.date(byAdding: .month, value: 1, to: candidate) ?? candidate
            } else {
                nextPay = candidate
                startPay = cal.date(byAdding: .month, value: -1, to: candidate) ?? candidate
            }
        } else {
            let diff = cal.dateComponents([.day], from: anchorDate, to: todayDate).day ?? 0
            let k = Int(floor(Double(diff) / Double(stepDays)))
            startPay = cal.date(byAdding: .day, value: k * stepDays, to: anchorDate) ?? todayDate
            if startPay > todayDate {
                startPay = cal.date(byAdding: .day, value: -stepDays, to: startPay) ?? startPay
            }
            nextPay = cal.date(byAdding: .day, value: stepDays, to: startPay) ?? todayDate
        }

        let endPay = cal.date(byAdding: .day, value: -1, to: nextPay) ?? nextPay
        let startStr = f.string(from: startPay)
        let endStr = f.string(from: endPay)

        let actualPay = snap.pays.first(where: { $0.kind == "pay" && $0.date == startStr })?.amount ?? s.pay_amount
        let spent = snap.pays
            .filter { $0.kind == "spend" && $0.date >= startStr && $0.date <= endStr }
            .reduce(0) { $0 + $1.amount }

        let setAside = estimateSetAside(settings: s, bills: snap.bills, payday: startPay, cal: cal)
        let allowance = max(0, actualPay - setAside)
        let left = allowance - spent
        let daysLeft = max(1, (cal.dateComponents([.day], from: todayDate, to: endPay).day ?? 0) + 1)
        let periodDays = max(1, (cal.dateComponents([.day], from: startPay, to: endPay).day ?? 0) + 1)

        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "en_GB")
        weekdayFmt.dateFormat = "EEEE"
        let nextLabel = weekdayFmt.string(from: nextPay)

        return PaydaysSummary(
            safePerWeekPence: safePerWeek,
            safePerDayPence: safePerDay,
            allowancePence: allowance,
            spentPence: spent,
            leftPence: left,
            perDayLeftPence: left > 0 ? left / daysLeft : 0,
            daysLeft: daysLeft,
            periodDays: periodDays,
            nextPaydayLabel: nextLabel,
            periodStart: startStr,
            periodEnd: endStr
        )
    }

    private func estimateSetAside(settings: PaydaysServerSettings, bills: [PaydaysBill], payday: Date, cal: Calendar) -> Int {
        // Mirror server.py's set_aside_for window calculation
        let activeBills = bills.filter(\.isActive)
        guard !activeBills.isEmpty else { return 0 }
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd"
        guard let anchor = f.date(from: settings.pay_anchor) else { return 0 }

        func daysInMonth(_ year: Int, _ month: Int) -> Int {
            var comps = DateComponents(year: year, month: month, day: 1)
            guard let d = cal.date(from: comps), let range = cal.range(of: .day, in: .month, for: d) else { return 30 }
            return range.count
        }

        let windowStart = cal.date(byAdding: .day, value: -150, to: payday) ?? payday
        let windowEnd = cal.date(byAdding: .day, value: 120, to: payday) ?? payday
        let payWindowStart = cal.date(byAdding: .day, value: -190, to: payday) ?? payday

        // Collect paydays
        var pays: [Date] = []
        if settings.pay_frequency == "monthly" {
            let anchorDay = cal.component(.day, from: anchor)
            var y = cal.component(.year, from: payWindowStart)
            var m = cal.component(.month, from: payWindowStart)
            for _ in 0..<24 {
                let d = cal.date(from: DateComponents(year: y, month: m, day: min(anchorDay, daysInMonth(y, m))))!
                if d > windowEnd { break }
                if d >= payWindowStart { pays.append(d) }
                m += 1
                if m > 12 { m = 1; y += 1 }
            }
        } else {
            let step = settings.pay_frequency == "fortnightly" ? 14 : (settings.pay_frequency == "fourweekly" ? 28 : 7)
            let diff = cal.dateComponents([.day], from: anchor, to: payWindowStart).day ?? 0
            let k = Int(ceil(Double(diff) / Double(step)))
            var d = cal.date(byAdding: .day, value: k * step, to: anchor) ?? payWindowStart
            while d <= windowEnd {
                pays.append(d)
                d = cal.date(byAdding: .day, value: step, to: d) ?? windowEnd.addingTimeInterval(86400)
            }
        }

        // Collect bill occurrences
        var occurrences: [(due: Date, bill: PaydaysBill)] = []
        var y = cal.component(.year, from: windowStart)
        var m = cal.component(.month, from: windowStart)
        for _ in 0..<24 {
            let firstOfMonth = cal.date(from: DateComponents(year: y, month: m, day: 1))!
            if firstOfMonth > windowEnd { break }
            let dim = daysInMonth(y, m)
            for bill in activeBills {
                let due = cal.date(from: DateComponents(year: y, month: m, day: min(bill.day, dim)))!
                if due >= windowStart && due <= windowEnd {
                    occurrences.append((due, bill))
                }
            }
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        occurrences.sort { ($0.due, $0.bill.name) < ($1.due, $1.bill.name) }

        var total = 0
        for i in occurrences.indices {
            let (due, bill) = occurrences[i]
            if due <= payday { continue }
            var window: [Date] = []
            for j in stride(from: i - 1, through: 0, by: -1) {
                let (prevDue, prev) = occurrences[j]
                if prevDue >= due || prev.amount * 2 < bill.amount { continue }
                window = pays.filter { $0 >= prevDue && $0 < due }
                if !window.isEmpty { break }
            }
            guard let idx = window.firstIndex(of: payday) else { continue }
            let share = bill.amount / window.count
            let extra = bill.amount % window.count
            total += share + (idx < extra ? 1 : 0)
        }

        let perYear: Double = settings.pay_frequency == "monthly" ? 12.0 :
            (settings.pay_frequency == "fortnightly" ? 365.25 / 14.0 :
             (settings.pay_frequency == "fourweekly" ? 365.25 / 28.0 : 365.25 / 7.0))
        if perYear > 0 && settings.savings > 0 {
            total += Int(ceil(Double(settings.savings * 12) / perYear))
        }
        return total
    }

    func statusLine() -> String {
        guard let s = summary else {
            return "Open Paydays in Keepwatch to check your balance."
        }
        if s.leftPence < 0 {
            return "Over by \(Self.formatPence(-s.leftPence)) until \(s.nextPaydayLabel)."
        }
        return "\(Self.formatPence(s.leftPence)) left until \(s.nextPaydayLabel) (\(Self.formatPence(s.perDayLeftPence)) a day)."
    }
}
