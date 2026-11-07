import Combine
import CoreBluetooth
import Foundation
import SwiftUI
import UserNotifications

enum GlucoseUnit: String, CaseIterable, Identifiable {
    case mmolL = "mmol/L"
    case mgdL = "mg/dL"
    var id: String { rawValue }
}

enum DexcomRegion: String, CaseIterable, Identifiable {
    case ous = "UK / International (shareous1)"
    case us = "United States (share2)"
    case jp = "Japan (share.dexcom.jp)"

    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .ous: return "https://shareous1.dexcom.com/ShareWebServices/Services"
        case .us: return "https://share2.dexcom.com/ShareWebServices/Services"
        case .jp: return "https://share.dexcom.jp/ShareWebServices/Services"
        }
    }
}

enum GlucoseTrend: String, Codable {
    case doubleUp = "DoubleUp"
    case singleUp = "SingleUp"
    case fortyFiveUp = "FortyFiveUp"
    case flat = "Flat"
    case fortyFiveDown = "FortyFiveDown"
    case singleDown = "SingleDown"
    case doubleDown = "DoubleDown"
    case unknown = "None"

    var arrow: String {
        switch self {
        case .doubleUp: return "↑↑"
        case .singleUp: return "↑"
        case .fortyFiveUp: return "↗"
        case .flat: return "→"
        case .fortyFiveDown: return "↘"
        case .singleDown: return "↓"
        case .doubleDown: return "↓↓"
        case .unknown: return "→"
        }
    }

    var label: String {
        switch self {
        case .doubleUp: return "Rising Rapidly"
        case .singleUp: return "Rising"
        case .fortyFiveUp: return "Rising Slightly"
        case .flat: return "Steady"
        case .fortyFiveDown: return "Falling Slightly"
        case .singleDown: return "Falling"
        case .doubleDown: return "Falling Rapidly"
        case .unknown: return "Steady"
        }
    }

    static func from(dexcomValue: Any?) -> GlucoseTrend {
        if let str = dexcomValue as? String {
            switch str.lowercased() {
            case "doubleup": return .doubleUp
            case "singleup": return .singleUp
            case "fortyfiveup": return .fortyFiveUp
            case "flat": return .flat
            case "fortyfivedown": return .fortyFiveDown
            case "singledown": return .singleDown
            case "doubledown": return .doubleDown
            default: return .flat
            }
        }
        if let num = dexcomValue as? Int {
            switch num {
            case 1: return .doubleUp
            case 2: return .singleUp
            case 3: return .fortyFiveUp
            case 4: return .flat
            case 5: return .fortyFiveDown
            case 6: return .singleDown
            case 7: return .doubleDown
            default: return .flat
            }
        }
        return .flat
    }
}

struct GlucoseReading: Identifiable, Codable, Equatable {
    var id: String { "\(Int(timestamp.timeIntervalSince1970))" }
    var mgdL: Int
    var timestamp: Date
    var trend: GlucoseTrend

    var mmolL: Double {
        (Double(mgdL) / 18.0182 * 10).rounded() / 10.0
    }
}

enum PumpEventType: String, Codable, CaseIterable, Identifiable {
    case mealBolus = "Meal Bolus"
    case autoCorrection = "Control-IQ Auto Bolus"
    case manualCorrection = "Correction Bolus"
    case basalModulation = "Control-IQ Basal"
    case carbs = "Carbs Logged"
    case siteChange = "Cartridge / Site Fill"
    case basalSuspend = "Control-IQ Basal Suspend"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .mealBolus: return "drop.fill"
        case .autoCorrection: return "sparkles"
        case .manualCorrection: return "drop.circle.fill"
        case .basalModulation: return "waveform.path.ecg"
        case .carbs: return "fork.knife"
        case .siteChange: return "syringe.fill"
        case .basalSuspend: return "pause.circle.fill"
        }
    }
}

struct PumpEvent: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var type: PumpEventType
    var timestamp: Date
    var insulinUnits: Double?
    var carbsGrams: Int?
    var basalRate: Double?
    var note: String?
}

struct TandemPumpStatus: Codable, Equatable {
    var iobUnits: Double = 1.65
    var cobGrams: Int = 18
    var activeBasalRate: Double = 0.95
    var scheduledBasalRate: Double = 0.85
    var batteryPercent: Int = 84
    var reservoirUnits: Double = 148.0
    var controlIQMode: String = "Control-IQ Active"
    var lastBolusUnits: Double = 3.20
    var lastBolusDate: Date = Date().addingTimeInterval(-48 * 60)
    var lastSyncDate: Date = Date()
    var pumpSerialNumber: String = "t:slim X2"
}

struct BLEPeripheralDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var category: String // "Dexcom G7" or "Tandem t:slim X2"
    var rssi: Int
    var lastSeen: Date
}

@MainActor
final class GlucoStore: NSObject, ObservableObject {
    // Persistent UserDefaults keys
    private static let unitKey = "gluco.unit"
    private static let lowMgdLKey = "gluco.lowMgdL"
    private static let highMgdLKey = "gluco.highMgdL"
    private static let urgentLowMgdLKey = "gluco.urgentLowMgdL"
    private static let dexcomUserKey = "gluco.dexcomUser"
    private static let dexcomPassKey = "gluco.dexcomPass"
    private static let dexcomRegionKey = "gluco.dexcomRegion"
    private static let nightscoutURLKey = "gluco.nightscoutURL"
    private static let nightscoutTokenKey = "gluco.nightscoutToken"
    private static let demoModeKey = "gluco.demoMode"
    private static let pumpStatusKey = "gluco.pumpStatus"
    private static let pumpEventsKey = "gluco.pumpEvents"

    @Published var unit: GlucoseUnit {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey) }
    }
    @Published var lowMgdL: Int {
        didSet { UserDefaults.standard.set(lowMgdL, forKey: Self.lowMgdLKey) }
    }
    @Published var highMgdL: Int {
        didSet { UserDefaults.standard.set(highMgdL, forKey: Self.highMgdLKey) }
    }
    @Published var urgentLowMgdL: Int {
        didSet { UserDefaults.standard.set(urgentLowMgdL, forKey: Self.urgentLowMgdLKey) }
    }

    @Published var dexcomUsername: String {
        didSet { UserDefaults.standard.set(dexcomUsername, forKey: Self.dexcomUserKey) }
    }
    @Published var dexcomPassword: String {
        didSet { UserDefaults.standard.set(dexcomPassword, forKey: Self.dexcomPassKey) }
    }
    @Published var dexcomRegion: DexcomRegion {
        didSet { UserDefaults.standard.set(dexcomRegion.rawValue, forKey: Self.dexcomRegionKey) }
    }

    @Published var nightscoutURL: String {
        didSet { UserDefaults.standard.set(nightscoutURL, forKey: Self.nightscoutURLKey) }
    }
    @Published var nightscoutToken: String {
        didSet { UserDefaults.standard.set(nightscoutToken, forKey: Self.nightscoutTokenKey) }
    }

    @Published var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: Self.demoModeKey)
            Task { await refreshAll() }
        }
    }

    @Published var readings: [GlucoseReading] = []
    @Published var pumpStatus: TandemPumpStatus {
        didSet {
            if let data = try? JSONEncoder().encode(pumpStatus) {
                UserDefaults.standard.set(data, forKey: Self.pumpStatusKey)
            }
        }
    }
    @Published var pumpEvents: [PumpEvent] {
        didSet {
            if let data = try? JSONEncoder().encode(pumpEvents) {
                UserDefaults.standard.set(data, forKey: Self.pumpEventsKey)
            }
        }
    }

    @Published var isSyncing: Bool = false
    @Published var dexcomConnected: Bool = false
    @Published var tandemConnected: Bool = false
    @Published var statusBanner: String = "Read-Only Monitor · Dexcom G7 + Tandem t:slim X2"
    @Published var bleDevices: [BLEPeripheralDevice] = []
    @Published var bleScanning: Bool = false

    private var dexcomSessionID: String?
    private var refreshTimer: Timer?
    private var centralManager: CBCentralManager?

    override init() {
        let d = UserDefaults.standard
        unit = GlucoseUnit(rawValue: d.string(forKey: Self.unitKey) ?? "") ?? .mmolL
        lowMgdL = d.object(forKey: Self.lowMgdLKey) as? Int ?? 70      // 3.9 mmol/L
        highMgdL = d.object(forKey: Self.highMgdLKey) as? Int ?? 180    // 10.0 mmol/L
        urgentLowMgdL = d.object(forKey: Self.urgentLowMgdLKey) as? Int ?? 54 // 3.0 mmol/L

        dexcomUsername = d.string(forKey: Self.dexcomUserKey) ?? ""
        dexcomPassword = d.string(forKey: Self.dexcomPassKey) ?? ""
        dexcomRegion = DexcomRegion(rawValue: d.string(forKey: Self.dexcomRegionKey) ?? "") ?? .ous

        nightscoutURL = d.string(forKey: Self.nightscoutURLKey) ?? ""
        nightscoutToken = d.string(forKey: Self.nightscoutTokenKey) ?? ""

        let hasCredentials = !(d.string(forKey: Self.dexcomUserKey) ?? "").isEmpty
            || !(d.string(forKey: Self.nightscoutURLKey) ?? "").isEmpty
        demoMode = d.object(forKey: Self.demoModeKey) as? Bool ?? !hasCredentials

        if let savedPump = d.data(forKey: Self.pumpStatusKey),
           let decoded = try? JSONDecoder().decode(TandemPumpStatus.self, from: savedPump) {
            pumpStatus = decoded
        } else {
            pumpStatus = TandemPumpStatus()
        }

        if let savedEvents = d.data(forKey: Self.pumpEventsKey),
           let decoded = try? JSONDecoder().decode([PumpEvent].self, from: savedEvents) {
            pumpEvents = decoded
        } else {
            pumpEvents = []
        }

        super.init()

        if readings.isEmpty {
            loadSimulatedData()
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    // MARK: - Formatting & Computed Stats

    func formatGlucose(_ mgdL: Int) -> String {
        switch unit {
        case .mmolL:
            let val = Double(mgdL) / 18.0182
            return String(format: "%.1f", val)
        case .mgdL:
            return "\(mgdL)"
        }
    }

    func formatDelta() -> String {
        guard readings.count >= 2 else { return "0.0" }
        let sorted = readings.sorted { $0.timestamp > $1.timestamp }
        let diffMgdL = sorted[0].mgdL - sorted[1].mgdL
        switch unit {
        case .mmolL:
            let diff = Double(diffMgdL) / 18.0182
            return String(format: "%+.1f", diff)
        case .mgdL:
            return String(format: "%+d", diffMgdL)
        }
    }

    var latestReading: GlucoseReading? {
        readings.max(by: { $0.timestamp < $1.timestamp })
    }

    func color(for mgdL: Int) -> Color {
        if mgdL <= urgentLowMgdL { return GlucoTheme.urgentRed }
        if mgdL < lowMgdL { return GlucoTheme.lowRed }
        if mgdL > highMgdL { return GlucoTheme.highAmber }
        return GlucoTheme.inRangeGreen
    }

    var timeInRangePercent: Int {
        guard !readings.isEmpty else { return 0 }
        let inRange = readings.filter { $0.mgdL >= lowMgdL && $0.mgdL <= highMgdL }.count
        return Int((Double(inRange) / Double(readings.count) * 100.0).rounded())
    }

    var timeBelowRangePercent: Int {
        guard !readings.isEmpty else { return 0 }
        let low = readings.filter { $0.mgdL < lowMgdL }.count
        return Int((Double(low) / Double(readings.count) * 100.0).rounded())
    }

    var timeAboveRangePercent: Int {
        max(0, 100 - timeInRangePercent - timeBelowRangePercent)
    }

    var averageMgdL: Int {
        guard !readings.isEmpty else { return 110 }
        let sum = readings.reduce(0) { $0 + $1.mgdL }
        return Int((Double(sum) / Double(readings.count)).rounded())
    }

    /// Glucose Management Indicator (GMI %) formula: 3.31 + 0.02392 * mean_mgdL
    var gmiPercent: String {
        let gmi = 3.31 + 0.02392 * Double(averageMgdL)
        return String(format: "%.1f%%", gmi)
    }

    var totalDailyInsulin: String {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let bolusSum = pumpEvents
            .filter { $0.timestamp >= cutoff }
            .compactMap { $0.insulinUnits }
            .reduce(0, +)
        let basalSum = pumpStatus.scheduledBasalRate * 24.0
        return String(format: "%.1f U", bolusSum + basalSum)
    }

    // MARK: - Data Sync Orchestrator

    func refreshAll() async {
        isSyncing = true
        defer { isSyncing = false }

        var fetchedAnyLive = false

        if !dexcomUsername.trimmingCharacters(in: .whitespaces).isEmpty && !dexcomPassword.isEmpty {
            let ok = await syncDexcomShare()
            dexcomConnected = ok
            if ok { fetchedAnyLive = true }
        }

        if !nightscoutURL.trimmingCharacters(in: .whitespaces).isEmpty {
            let ok = await syncNightscout()
            tandemConnected = ok
            if ok { fetchedAnyLive = true }
        }

        if demoMode && !fetchedAnyLive {
            loadSimulatedData()
            statusBanner = "Demo Telemetry Active · Sign in to Dexcom / Tandem in Settings"
        } else if fetchedAnyLive {
            statusBanner = "Live Telemetry · Updated \(Self.shortTime(Date()))"
            checkGlucoseAlerts()
        }
    }

    // MARK: - 1. Direct Dexcom G7 Share Cloud API

    func syncDexcomShare() async -> Bool {
        let appId = "d89443d2-327c-4a6f-89e5-496bbb0317db"
        let base = dexcomRegion.baseURL

        do {
            if dexcomSessionID == nil {
                // Step 1: AuthenticatePublisherAccount -> returns accountId
                guard let authURL = URL(string: "\(base)/General/AuthenticatePublisherAccount") else { return false }
                var authReq = URLRequest(url: authURL, timeoutInterval: 15)
                authReq.httpMethod = "POST"
                authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                authReq.setValue("application/json", forHTTPHeaderField: "Accept")
                let authBody: [String: String] = [
                    "accountName": dexcomUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                    "password": dexcomPassword,
                    "applicationId": appId
                ]
                authReq.httpBody = try JSONSerialization.data(withJSONObject: authBody)
                let (authData, authResp) = try await URLSession.shared.data(for: authReq)
                guard let http1 = authResp as? HTTPURLResponse, (200..<300).contains(http1.statusCode) else {
                    return false
                }
                let accountId = String(data: authData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
                guard !accountId.isEmpty, accountId != "00000000-0000-0000-0000-000000000000" else {
                    return false
                }

                // Step 2: LoginPublisherAccountById -> returns sessionId
                guard let loginURL = URL(string: "\(base)/General/LoginPublisherAccountById") else { return false }
                var loginReq = URLRequest(url: loginURL, timeoutInterval: 15)
                loginReq.httpMethod = "POST"
                loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                loginReq.setValue("application/json", forHTTPHeaderField: "Accept")
                let loginBody: [String: String] = [
                    "accountId": accountId,
                    "password": dexcomPassword,
                    "applicationId": appId
                ]
                loginReq.httpBody = try JSONSerialization.data(withJSONObject: loginBody)
                let (loginData, loginResp) = try await URLSession.shared.data(for: loginReq)
                guard let http2 = loginResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
                    return false
                }
                let sessionId = String(data: loginData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
                guard !sessionId.isEmpty, sessionId != "00000000-0000-0000-0000-000000000000" else {
                    return false
                }
                dexcomSessionID = sessionId
            }

            guard let sid = dexcomSessionID,
                  let egvURL = URL(string: "\(base)/Publisher/ReadPublisherLatestGlucoseValues?sessionId=\(sid)&minutes=1440&maxCount=288") else {
                return false
            }
            var egvReq = URLRequest(url: egvURL, timeoutInterval: 15)
            egvReq.httpMethod = "POST"
            egvReq.setValue("application/json", forHTTPHeaderField: "Accept")
            let (egvData, egvResp) = try await URLSession.shared.data(for: egvReq)
            guard let http3 = egvResp as? HTTPURLResponse, (200..<300).contains(http3.statusCode) else {
                dexcomSessionID = nil
                return false
            }

            guard let arr = try JSONSerialization.jsonObject(with: egvData) as? [[String: Any]] else {
                return false
            }

            var parsed: [GlucoseReading] = []
            for item in arr {
                guard let val = item["Value"] as? Int, val > 20 else { continue }
                let wt = item["WT"] as? String ?? ""
                let ts = Self.parseDexcomDate(wt) ?? Date()
                let trend = GlucoseTrend.from(dexcomValue: item["Trend"])
                parsed.append(GlucoseReading(mgdL: val, timestamp: ts, trend: trend))
            }

            if !parsed.isEmpty {
                readings = parsed.sorted { $0.timestamp < $1.timestamp }
                return true
            }
            return false
        } catch {
            dexcomSessionID = nil
            return false
        }
    }

    private static func parseDexcomDate(_ wt: String) -> Date? {
        // Format: "Date(1730982000000)" or "/Date(1730982000000+0000)/"
        let digits = wt.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .filter { $0.count >= 10 }
        if let first = digits.first, let ms = Double(first) {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        return nil
    }

    // MARK: - 2. Nightscout / Tandem tconnectsync API

    func syncNightscout() async -> Bool {
        var base = nightscoutURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "https://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }

        let tokenParam = nightscoutToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = tokenParam.isEmpty ? "" : "&token=\(tokenParam)"

        var anySuccess = false

        // 2a. Entries (if Dexcom Share isn't already driving readings)
        if let entriesURL = URL(string: "\(base)/api/v1/entries/sgv.json?count=288\(suffix)") {
            do {
                let (data, resp) = try await URLSession.shared.data(from: entriesURL)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var parsed: [GlucoseReading] = []
                    for item in arr {
                        guard let sgv = item["sgv"] as? Int, sgv > 20 else { continue }
                        let ms = (item["date"] as? Double) ?? Double(item["date"] as? Int ?? 0)
                        let dt = ms > 0 ? Date(timeIntervalSince1970: ms / 1000.0) : Date()
                        let dir = GlucoseTrend.from(dexcomValue: item["direction"])
                        parsed.append(GlucoseReading(mgdL: sgv, timestamp: dt, trend: dir))
                    }
                    if !parsed.isEmpty {
                        readings = parsed.sorted { $0.timestamp < $1.timestamp }
                        anySuccess = true
                    }
                }
            } catch {}
        }

        // 2b. DeviceStatus (Tandem t:slim X2 pump status: IOB, reservoir, battery, Control-IQ)
        if let statusURL = URL(string: "\(base)/api/v1/devicestatus.json?count=5\(suffix)") {
            do {
                let (data, resp) = try await URLSession.shared.data(from: statusURL)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for entry in arr {
                        if let pump = entry["pump"] as? [String: Any] {
                            if let iobDict = pump["iob"] as? [String: Any],
                               let iob = iobDict["bolusiob"] as? Double ?? iobDict["iob"] as? Double {
                                pumpStatus.iobUnits = iob
                            }
                            if let res = pump["reservoir"] as? Double {
                                pumpStatus.reservoirUnits = res
                            } else if let resInt = pump["reservoir"] as? Int {
                                pumpStatus.reservoirUnits = Double(resInt)
                            }
                            if let batt = pump["battery"] as? [String: Any],
                               let pct = batt["percent"] as? Int {
                                pumpStatus.batteryPercent = pct
                            }
                            if let status = pump["status"] as? [String: Any],
                               let statusStr = status["status"] as? String {
                                pumpStatus.controlIQMode = "Control-IQ (\(statusStr.capitalized))"
                            }
                            pumpStatus.lastSyncDate = Date()
                            anySuccess = true
                            break
                        }
                    }
                }
            } catch {}
        }

        // 2c. Treatments (Tandem boluses, Control-IQ corrections, temp basals, carbs)
        if let treatURL = URL(string: "\(base)/api/v1/treatments.json?count=35\(suffix)") {
            do {
                let (data, resp) = try await URLSession.shared.data(from: treatURL)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var parsedEvents: [PumpEvent] = []
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let isoFallback = ISO8601DateFormatter()

                    for item in arr {
                        let eventTypeStr = (item["eventType"] as? String ?? "").lowercased()
                        let createdAt = item["created_at"] as? String ?? ""
                        let dt = iso.date(from: createdAt) ?? isoFallback.date(from: createdAt) ?? Date()
                        let insulin = item["insulin"] as? Double
                        let carbs = item["carbs"] as? Int ?? (item["carbs"] as? Double).map { Int($0) }
                        let rate = item["rate"] as? Double ?? item["absolute"] as? Double
                        let notes = item["notes"] as? String

                        let pType: PumpEventType
                        if eventTypeStr.contains("correction") {
                            pType = .autoCorrection
                        } else if let ins = insulin, ins > 0 {
                            pType = (carbs ?? 0) > 0 ? .mealBolus : .manualCorrection
                        } else if let c = carbs, c > 0 {
                            pType = .carbs
                        } else if eventTypeStr.contains("temp basal") || rate != nil {
                            pType = (rate == 0) ? .basalSuspend : .basalModulation
                        } else if eventTypeStr.contains("site") || eventTypeStr.contains("insulin change") {
                            pType = .siteChange
                        } else {
                            continue
                        }

                        parsedEvents.append(PumpEvent(
                            id: (item["_id"] as? String) ?? UUID().uuidString,
                            type: pType,
                            timestamp: dt,
                            insulinUnits: insulin,
                            carbsGrams: carbs,
                            basalRate: rate,
                            note: notes
                        ))
                    }

                    if !parsedEvents.isEmpty {
                        pumpEvents = parsedEvents.sorted { $0.timestamp > $1.timestamp }
                        if let latestBolus = pumpEvents.first(where: { ($0.insulinUnits ?? 0) > 0 }) {
                            pumpStatus.lastBolusUnits = latestBolus.insulinUnits ?? pumpStatus.lastBolusUnits
                            pumpStatus.lastBolusDate = latestBolus.timestamp
                        }
                        anySuccess = true
                    }
                }
            } catch {}
        }

        return anySuccess
    }

    // MARK: - 3. Read-Only Bluetooth LE Proximity Scanner (G7 & t:slim X2)

    func toggleBLEScan() {
        if bleScanning {
            centralManager?.stopScan()
            bleScanning = false
        } else {
            if centralManager == nil {
                centralManager = CBCentralManager(delegate: self, queue: nil)
            } else if centralManager?.state == .poweredOn {
                centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                bleScanning = true
            }
        }
    }

    // MARK: - 4. Manual Pump Entry / Quick Log

    func logPumpEvent(type: PumpEventType, insulin: Double?, carbs: Int?, basal: Double?, note: String?) {
        let ev = PumpEvent(
            type: type,
            timestamp: Date(),
            insulinUnits: insulin,
            carbsGrams: carbs,
            basalRate: basal,
            note: note
        )
        pumpEvents.insert(ev, at: 0)
        if let ins = insulin, ins > 0 {
            pumpStatus.lastBolusUnits = ins
            pumpStatus.lastBolusDate = Date()
            pumpStatus.iobUnits = ((pumpStatus.iobUnits + ins) * 100).rounded() / 100.0
        }
        if let c = carbs, c > 0 {
            pumpStatus.cobGrams += c
        }
        if let b = basal {
            pumpStatus.activeBasalRate = b
        }
        pumpStatus.lastSyncDate = Date()
    }

    // MARK: - 5. Simulated Realistic G7 + t:slim X2 Control-IQ Telemetry

    func loadSimulatedData() {
        let now = Date()
        var simReadings: [GlucoseReading] = []
        // Generate 24 hours (288 readings at 5-minute intervals)
        for i in stride(from: 287, through: 0, by: -1) {
            let t = now.addingTimeInterval(Double(-i * 300))
            let hoursAgo = Double(i) * 5.0 / 60.0
            let wave1 = 28.0 * sin(hoursAgo * 0.65)
            let wave2 = 16.0 * cos(hoursAgo * 1.35)
            let mealBump = 42.0 * exp(-pow(hoursAgo - 2.1, 2) / 0.9) + 34.0 * exp(-pow(hoursAgo - 7.5, 2) / 1.2)
            let mg = max(62, min(235, Int((114.0 + wave1 + wave2 + mealBump).rounded())))

            let prevWave = 114.0 + 28.0 * sin((hoursAgo + 0.083) * 0.65) + 16.0 * cos((hoursAgo + 0.083) * 1.35)
            let delta = Double(mg) - prevWave
            let trend: GlucoseTrend
            if delta > 9 { trend = .singleUp }
            else if delta > 4 { trend = .fortyFiveUp }
            else if delta < -9 { trend = .singleDown }
            else if delta < -4 { trend = .fortyFiveDown }
            else { trend = .flat }

            simReadings.append(GlucoseReading(mgdL: mg, timestamp: t, trend: trend))
        }
        readings = simReadings

        if pumpEvents.isEmpty {
            pumpEvents = [
                PumpEvent(type: .basalModulation, timestamp: now.addingTimeInterval(-15 * 60), insulinUnits: nil, carbsGrams: nil, basalRate: 1.15, note: "Control-IQ increased basal to 1.15 U/hr"),
                PumpEvent(type: .mealBolus, timestamp: now.addingTimeInterval(-65 * 60), insulinUnits: 3.40, carbsGrams: 42, basalRate: nil, note: "Lunch meal bolus (Control-IQ)"),
                PumpEvent(type: .autoCorrection, timestamp: now.addingTimeInterval(-140 * 60), insulinUnits: 0.85, carbsGrams: nil, basalRate: nil, note: "Control-IQ automatic correction bolus"),
                PumpEvent(type: .basalModulation, timestamp: now.addingTimeInterval(-210 * 60), insulinUnits: nil, carbsGrams: nil, basalRate: 0.85, note: "Control-IQ scheduled profile basal"),
                PumpEvent(type: .mealBolus, timestamp: now.addingTimeInterval(-360 * 60), insulinUnits: 4.10, carbsGrams: 50, basalRate: nil, note: "Breakfast bolus"),
                PumpEvent(type: .siteChange, timestamp: now.addingTimeInterval(-19 * 3600), insulinUnits: nil, carbsGrams: nil, basalRate: nil, note: "Filled cartridge (200 U) & tubing prime")
            ]
        }
    }

    private func checkGlucoseAlerts() {
        guard let latest = latestReading else { return }
        let content = UNMutableNotificationContent()
        if latest.mgdL <= urgentLowMgdL {
            content.title = "Urgent Low Glucose (\(formatGlucose(latest.mgdL)) \(unit.rawValue))"
            content.body = "Dexcom G7 is \(latest.trend.label.lowercased()) (\(latest.trend.arrow)). Tandem IOB: \(String(format: "%.2f U", pumpStatus.iobUnits))."
            content.sound = .defaultCritical
        } else if latest.mgdL < lowMgdL {
            content.title = "Low Glucose (\(formatGlucose(latest.mgdL)) \(unit.rawValue))"
            content.body = "Dexcom G7 reading is below target (\(latest.trend.arrow)). Active IOB: \(String(format: "%.2f U", pumpStatus.iobUnits))."
            content.sound = .default
        } else if latest.mgdL > highMgdL {
            content.title = "High Glucose (\(formatGlucose(latest.mgdL)) \(unit.rawValue))"
            content.body = "Dexcom G7 reading is above target (\(latest.trend.arrow)). Active IOB: \(String(format: "%.2f U", pumpStatus.iobUnits))."
            content.sound = .default
        } else {
            return
        }
        let req = UNNotificationRequest(identifier: "gluco.alert", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }
}

extension GlucoStore: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let isOn = central.state == .poweredOn
        Task { @MainActor in
            if isOn && self.bleScanning {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rawName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let upper = trimmed.uppercased()
        let category: String
        if upper.contains("DXCM") || upper.contains("DEXCOM") || upper.hasPrefix("DX") {
            category = "Dexcom G7"
        } else if upper.contains("TSLIM") || upper.contains("T:SLIM") || upper.contains("TANDEM") {
            category = "Tandem t:slim X2"
        } else {
            return
        }

        let dev = BLEPeripheralDevice(
            id: peripheral.identifier.uuidString,
            name: trimmed,
            category: category,
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        Task { @MainActor in
            if let idx = self.bleDevices.firstIndex(where: { $0.id == dev.id }) {
                self.bleDevices[idx] = dev
            } else {
                self.bleDevices.append(dev)
            }
        }
    }
}

enum GlucoTheme {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.11)
    static let card = Color(red: 0.09, green: 0.12, blue: 0.19)
    static let cardElevated = Color(red: 0.12, green: 0.16, blue: 0.25)
    static let border = Color.white.opacity(0.09)
    static let textPrimary = Color(red: 0.96, green: 0.98, blue: 1.0)
    static let textSecondary = Color(red: 0.58, green: 0.66, blue: 0.78)
    static let inRangeGreen = Color(red: 0.18, green: 0.84, blue: 0.48)
    static let highAmber = Color(red: 0.98, green: 0.68, blue: 0.16)
    static let lowRed = Color(red: 0.96, green: 0.32, blue: 0.36)
    static let urgentRed = Color(red: 0.90, green: 0.14, blue: 0.24)
    static let tandemCyan = Color(red: 0.22, green: 0.74, blue: 0.97)
    static let controlIQPurple = Color(red: 0.66, green: 0.52, blue: 0.98)
}
