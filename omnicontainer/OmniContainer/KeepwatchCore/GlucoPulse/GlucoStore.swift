import Combine
import CoreBluetooth
import Foundation
import SwiftUI
import UIKit
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
    static let shared = GlucoStore()

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
    private static let tandemEmailKey = "gluco.tandemEmail"
    private static let tandemPassKey = "gluco.tandemPass"
    private static let tandemRegionKey = "gluco.tandemRegion"
    private static let tandemSerialKey = "gluco.tandemSerial"
    private static let g7DirectBLEKey = "gluco.g7DirectBLE"
    private static let savedG7UUIDKey = "gluco.savedG7UUID"
    private static let g7PairingCodeKey = "gluco.g7PairingCode"
    private static let g7SensorNameKey = "gluco.g7SensorName"

    // Dexcom G7 & Tandem GATT Service & Characteristic UUIDs (LoopKit / G7SensorKit / xdripswift spec)
    nonisolated static let g7AdvServiceUUID = CBUUID(string: "FEBC")
    nonisolated static let g7CGMServiceUUID = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7AltServiceUUID = CBUUID(string: "F8084532-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7ReadCharUUID = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7ControlCharUUID = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7AuthCharUUID = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7BackfillCharUUID = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7AuthStreamCharUUID = CBUUID(string: "F8083538-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let tandemServiceUUID1 = CBUUID(string: "FDFB")
    nonisolated static let tandemServiceUUID2 = CBUUID(string: "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let deviceInfoServiceUUID = CBUUID(string: "180A")
    nonisolated static let batteryServiceUUID = CBUUID(string: "180F")

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

    @Published var tandemEmail: String {
        didSet { UserDefaults.standard.set(tandemEmail, forKey: Self.tandemEmailKey) }
    }
    @Published var tandemPassword: String {
        didSet { UserDefaults.standard.set(tandemPassword, forKey: Self.tandemPassKey) }
    }
    @Published var tandemRegion: String {
        didSet { UserDefaults.standard.set(tandemRegion, forKey: Self.tandemRegionKey) }
    }
    @Published var tandemPumpSerial: String {
        didSet { UserDefaults.standard.set(tandemPumpSerial, forKey: Self.tandemSerialKey) }
    }
    @Published var g7DirectBLEEnabled: Bool {
        didSet {
            UserDefaults.standard.set(g7DirectBLEEnabled, forKey: Self.g7DirectBLEKey)
            if g7DirectBLEEnabled { startDirectG7BLE() }
        }
    }
    @Published var g7PairingCode: String {
        didSet {
            let trimmed = g7PairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: Self.g7PairingCodeKey)
            g7Authenticator.pairingCode = trimmed
        }
    }

    @Published var isSyncing: Bool = false
    @Published var dexcomConnected: Bool = false
    @Published var dexcomDiagnostic: String = ""
    @Published var tandemConnected: Bool = false
    @Published var tandemDiagnostic: String = ""
    @Published var statusBanner: String = "Standalone G7 BLE + Tandem Source · No Dexcom App Needed"
    @Published var bleDevices: [BLEPeripheralDevice] = []
    @Published var bleScanning: Bool = false
    @Published var showAllBLEDevices: Bool = false
    @Published var bleScanElapsedSeconds: Int = 0
    @Published var g7BLEStatus: String = "Listening for Dexcom G7 (DXCM) over Bluetooth LE…"
    @Published var g7BLEConnectedName: String = ""
    @Published var lastBLEGlucoseDate: Date?

    private var dexcomSessionID: String?
    private var refreshTimer: Timer?
    private var bleFastTimer: Timer?
    private var centralManager: CBCentralManager?
    private var g7Peripherals: [UUID: CBPeripheral] = [:]
    private var allDiscoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var g7LastSensorTimestamp: UInt32 = 0

    // Dexcom G7 Native Primary J-PAKE + Saved-Key + Coexistence State
    private let g7Authenticator = DexcomG7NativeAuthenticator()
    private var g7AuthChar: CBCharacteristic?
    private var g7AuthStreamChar: CBCharacteristic?
    private var g7ControlChar: CBCharacteristic?
    private var g7BackfillChar: CBCharacteristic?
    private var g7AuthStreamBuffer = Data()
    private var g7PendingPakePhase: UInt8?
    private var g7PendingCertPhase: UInt8?
    private var g7PendingCertSize: Int?
    private var g7ExpectedCertPhase: UInt8 = 0
    private var g7PendingProofChallenge: Data?
    private var g7UsingFullBootstrap: Bool = false
    private var g7InitialPacketSent: Bool = false
    private var g7ChallengeResponseSent: Bool = false
    private var g7CertExchangeStarted: Bool = false
    private var g7WriteGeneration: Int = 0

    override init() {
        let d = UserDefaults.standard
        unit = GlucoseUnit(rawValue: d.string(forKey: Self.unitKey) ?? "") ?? .mmolL
        lowMgdL = d.object(forKey: Self.lowMgdLKey) as? Int ?? 70      // 3.9 mmol/L
        highMgdL = d.object(forKey: Self.highMgdLKey) as? Int ?? 180    // 10.0 mmol/L
        urgentLowMgdL = d.object(forKey: Self.urgentLowMgdLKey) as? Int ?? 54 // 3.0 mmol/L

        dexcomUsername = d.string(forKey: Self.dexcomUserKey) ?? ""
        dexcomPassword = d.string(forKey: Self.dexcomPassKey) ?? ""
        dexcomRegion = DexcomRegion(rawValue: d.string(forKey: Self.dexcomRegionKey) ?? "") ?? .ous

        nightscoutURL = d.string(forKey: Self.nightscoutURLKey) ?? "http://100.85.127.42:1337"
        nightscoutToken = d.string(forKey: Self.nightscoutTokenKey) ?? ""

        tandemEmail = d.string(forKey: Self.tandemEmailKey) ?? (d.string(forKey: Self.dexcomUserKey) ?? "")
        tandemPassword = d.string(forKey: Self.tandemPassKey) ?? ""
        tandemRegion = d.string(forKey: Self.tandemRegionKey) ?? "EU"
        tandemPumpSerial = d.string(forKey: Self.tandemSerialKey) ?? ""
        g7DirectBLEEnabled = d.object(forKey: Self.g7DirectBLEKey) as? Bool ?? true
        let savedCode = d.string(forKey: Self.g7PairingCodeKey) ?? ""
        g7PairingCode = savedCode
        let savedSensorName = d.string(forKey: Self.g7SensorNameKey) ?? "DXCMAK"
        g7BLEConnectedName = savedSensorName

        let hasCredentials = !(d.string(forKey: Self.dexcomUserKey) ?? "").isEmpty
            || !(d.string(forKey: Self.nightscoutURLKey) ?? "").isEmpty
            || !(d.string(forKey: Self.tandemEmailKey) ?? "").isEmpty
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

        g7Authenticator.transmitterID = savedSensorName
        g7Authenticator.pairingCode = savedCode
        g7Authenticator.restorePersistedSharedKey()

        if readings.isEmpty {
            loadSimulatedData()
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        if g7DirectBLEEnabled {
            startDirectG7BLE()
        }

        Task { @MainActor in
            await self.fetchTrueNASBridgeConfig()
            await self.refreshAll()
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollConnectedG7Peripherals()
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

    private static func candidateAccountNames(for rawInput: String) -> [String] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates: [String] = [trimmed]
        let lower = trimmed.lowercased()
        if !candidates.contains(lower) { candidates.append(lower) }

        let compact = trimmed.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        if !candidates.contains(compact) { candidates.append(compact) }

        let digitsOnly = compact.filter { $0.isNumber }
        if compact.hasPrefix("07") && digitsOnly.count == 11 {
            let ukIntl = "+44" + String(digitsOnly.dropFirst())
            let ukNoPlus = "44" + String(digitsOnly.dropFirst())
            if !candidates.contains(ukIntl) { candidates.append(ukIntl) }
            if !candidates.contains(ukNoPlus) { candidates.append(ukNoPlus) }
        } else if compact.hasPrefix("+44") && digitsOnly.count >= 11 {
            let localUK = "0" + String(digitsOnly.dropFirst(2))
            if !candidates.contains(localUK) { candidates.append(localUK) }
        } else if compact.hasPrefix("447") && digitsOnly.count == 12 {
            let ukIntl = "+" + digitsOnly
            let localUK = "0" + String(digitsOnly.dropFirst(2))
            if !candidates.contains(ukIntl) { candidates.append(ukIntl) }
            if !candidates.contains(localUK) { candidates.append(localUK) }
        }
        return candidates
    }

    func syncDexcomShare() async -> Bool {
        let appId = "d89443d2-327c-4a6f-89e5-496bbb0317db"
        let userAgent = "Dexcom Share/3.0.2.11 CFNetwork/672.0.2 Darwin/14.0.0"
        let password = dexcomPassword
        let candidates = Self.candidateAccountNames(for: dexcomUsername)
        guard !candidates.isEmpty, !password.isEmpty else {
            dexcomDiagnostic = "Please enter your Dexcom username/email/phone and password."
            return false
        }

        var regionsToTry: [DexcomRegion] = [dexcomRegion]
        for r in DexcomRegion.allCases where r != dexcomRegion {
            regionsToTry.append(r)
        }

        var activeBase = dexcomRegion.baseURL
        var lastErrorCode = ""
        var lastErrorMessage = ""

        if dexcomSessionID == nil {
            outerLoop: for region in regionsToTry {
                let base = region.baseURL
                let regionAppId = (region == .jp) ? "d8665ade-9673-4e27-9ff6-92db4ce13d13" : appId
                for accountName in candidates {
                    do {
                        guard let authURL = URL(string: "\(base)/General/AuthenticatePublisherAccount") else { continue }
                        var authReq = URLRequest(url: authURL, timeoutInterval: 15)
                        authReq.httpMethod = "POST"
                        authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        authReq.setValue("application/json", forHTTPHeaderField: "Accept")
                        authReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                        let authBody: [String: String] = [
                            "accountName": accountName,
                            "password": password,
                            "applicationId": regionAppId
                        ]
                        authReq.httpBody = try JSONSerialization.data(withJSONObject: authBody)
                        let (authData, authResp) = try await URLSession.shared.data(for: authReq)
                        let status1 = (authResp as? HTTPURLResponse)?.statusCode ?? 0

                        if (200..<300).contains(status1) {
                            let accountId = String(data: authData, encoding: .utf8)?
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
                            if !accountId.isEmpty && accountId != "00000000-0000-0000-0000-000000000000" {
                                if let loginURL = URL(string: "\(base)/General/LoginPublisherAccountById") {
                                    var loginReq = URLRequest(url: loginURL, timeoutInterval: 15)
                                    loginReq.httpMethod = "POST"
                                    loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                    loginReq.setValue("application/json", forHTTPHeaderField: "Accept")
                                    loginReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                                    let loginBody: [String: String] = [
                                        "accountId": accountId,
                                        "password": password,
                                        "applicationId": regionAppId
                                    ]
                                    loginReq.httpBody = try JSONSerialization.data(withJSONObject: loginBody)
                                    let (loginData, loginResp) = try await URLSession.shared.data(for: loginReq)
                                    if let http2 = loginResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) {
                                        let sessionId = String(data: loginData, encoding: .utf8)?
                                            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
                                        if !sessionId.isEmpty && sessionId != "00000000-0000-0000-0000-000000000000" {
                                            dexcomSessionID = sessionId
                                            activeBase = base
                                            if dexcomRegion != region { dexcomRegion = region }
                                            break outerLoop
                                        }
                                    }
                                }
                            }
                        } else if region == dexcomRegion || lastErrorCode.isEmpty {
                            if let errJson = try? JSONSerialization.jsonObject(with: authData) as? [String: Any] {
                                let code = errJson["Code"] as? String ?? "HTTP \(status1)"
                                if code != "ApplicationNotAuthenticated" || lastErrorCode.isEmpty {
                                    lastErrorCode = code
                                    lastErrorMessage = errJson["Message"] as? String ?? ""
                                }
                            } else if lastErrorCode.isEmpty {
                                lastErrorCode = "HTTP \(status1)"
                            }
                        }

                        if let byNameURL = URL(string: "\(base)/General/LoginPublisherAccountByName") {
                            var nameReq = URLRequest(url: byNameURL, timeoutInterval: 15)
                            nameReq.httpMethod = "POST"
                            nameReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            nameReq.setValue("application/json", forHTTPHeaderField: "Accept")
                            nameReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                            nameReq.httpBody = try JSONSerialization.data(withJSONObject: authBody)
                            let (nameData, nameResp) = try await URLSession.shared.data(for: nameReq)
                            if let httpN = nameResp as? HTTPURLResponse, (200..<300).contains(httpN.statusCode) {
                                let sessionId = String(data: nameData, encoding: .utf8)?
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
                                if !sessionId.isEmpty && sessionId != "00000000-0000-0000-0000-000000000000" {
                                    dexcomSessionID = sessionId
                                    activeBase = base
                                    if dexcomRegion != region { dexcomRegion = region }
                                    break outerLoop
                                }
                            }
                        }
                    } catch {
                        lastErrorMessage = error.localizedDescription
                    }
                }
            }
        }

        guard let sid = dexcomSessionID else {
            if lastErrorCode == "AccountPasswordInvalid" || lastErrorCode == "SSO_AuthenticateAccountNotFound" {
                dexcomDiagnostic = "Dexcom Share rejected login (\(lastErrorCode)). Note: (1) In the Dexcom G7 iPhone app ? Connections ? Share, 'Share' MUST be turned ON with at least 1 follower (you can invite your own email) before Dexcom activates Share API access for your account. (2) If your Dexcom ID is a UK phone number, try +447... or check your exact Username under Dexcom G7 ? Profile ? Account."
            } else if !lastErrorCode.isEmpty {
                dexcomDiagnostic = "Dexcom Share error (\(lastErrorCode)): \(lastErrorMessage)"
            } else {
                dexcomDiagnostic = "Could not reach Dexcom Share (\(lastErrorMessage))."
            }
            return false
        }

        do {
            guard let egvURL = URL(string: "\(activeBase)/Publisher/ReadPublisherLatestGlucoseValues?sessionId=\(sid)&minutes=1440&maxCount=288") else {
                return false
            }
            var egvReq = URLRequest(url: egvURL, timeoutInterval: 15)
            egvReq.httpMethod = "POST"
            egvReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            egvReq.setValue("application/json", forHTTPHeaderField: "Accept")
            egvReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (egvData, egvResp) = try await URLSession.shared.data(for: egvReq)
            guard let http3 = egvResp as? HTTPURLResponse, (200..<300).contains(http3.statusCode) else {
                dexcomSessionID = nil
                dexcomDiagnostic = "Session expired ? tap Connect & Sync again."
                return false
            }

            guard let arr = try JSONSerialization.jsonObject(with: egvData) as? [[String: Any]] else {
                dexcomDiagnostic = "Connected to Dexcom Share, but response format was unexpected."
                return true
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
                mergeReadings(parsed)
                dexcomDiagnostic = "Connected to Dexcom Share (\(readings.count) readings loaded)."
                return true
            } else {
                dexcomDiagnostic = "Dexcom login verified (0 cloud readings because the official Dexcom app is not needed). GlucoPulse is listening directly via G7 Bluetooth LE + Tandem Source CGM."
                return true
            }
        } catch {
            dexcomSessionID = nil
            dexcomDiagnostic = "Error fetching Dexcom readings: \(error.localizedDescription)"
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
                        mergeReadings(parsed)
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

    // MARK: - 2b. TrueNAS Tandem Source Bridge API (:1338) — Standalone G7 CGM via t:slim X2

    var truenasBridgeBaseURL: String {
        var base = nightscoutURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "http://100.85.127.42:1338" }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix(":1337") {
            return String(base.dropLast(5)) + ":1338"
        }
        return "http://100.85.127.42:1338"
    }

    func fetchTrueNASBridgeConfig() async {
        guard let url = URL(string: "\(truenasBridgeBaseURL)/api/config") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let email = json["tconnect_email"] as? String, !email.isEmpty, tandemEmail.isEmpty {
                tandemEmail = email
            }
            if let reg = json["tconnect_region"] as? String, !reg.isEmpty {
                tandemRegion = reg
            }
            if let serial = json["pump_serial"] as? String, !serial.isEmpty, tandemPumpSerial.isEmpty {
                tandemPumpSerial = serial
            }
            if let st = json["status"] as? [String: Any],
               let lastRes = st["last_tconnect_result"] as? String {
                tandemDiagnostic = lastRes
            }
        } catch {}
    }

    func saveAndSyncTandemSource() async -> Bool {
        let email = tandemEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            tandemDiagnostic = "Enter your Tandem Source email address and password."
            return false
        }
        guard let url = URL(string: "\(truenasBridgeBaseURL)/api/config") else { return false }
        tandemDiagnostic = "Saving to TrueNAS Bridge & syncing Tandem Source (Pump + G7 CGM)…"
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "tconnect_email": email,
                "tconnect_password": tandemPassword,
                "tconnect_region": tandemRegion,
                "pump_serial": tandemPumpSerial.trimmingCharacters(in: .whitespacesAndNewlines),
                "tconnect_features": "BASAL BOLUS IOB PUMP_EVENTS PUMP_EVENTS_BASAL_SUSPENSION PROFILES CGM CGM_ALERTS DEVICE_STATUS",
                "dexcom_username": dexcomUsername,
                "dexcom_password": dexcomPassword,
                "dexcom_region": (dexcomRegion == .ous ? "ous" : (dexcomRegion == .us ? "us" : "jp"))
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                tandemDiagnostic = "Could not reach TrueNAS Bridge at \(truenasBridgeBaseURL)."
                return false
            }

            // Poll /api/status while tconnectsync runs
            if let statusURL = URL(string: "\(truenasBridgeBaseURL)/api/status") {
                for _ in 0..<12 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if let (sData, _) = try? await URLSession.shared.data(from: statusURL),
                       let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any] {
                        let running = (sJson["running_now"] as? Bool) ?? false
                        let resStr = (sJson["last_tconnect_result"] as? String) ?? ""
                        if !resStr.isEmpty {
                            tandemDiagnostic = resStr
                        }
                        if !running { break }
                    }
                }
            }

            let nsOK = await syncNightscout()
            tandemConnected = nsOK || tandemDiagnostic.lowercased().contains("success")
            if tandemConnected { demoMode = false }
            return tandemConnected
        } catch {
            tandemDiagnostic = "Bridge error: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 3. Direct Dexcom G7 Bluetooth LE GATT Reader + Proximity Scanner (No Dexcom App Needed)

    func mergeReadings(_ incoming: [GlucoseReading]) {
        guard !incoming.isEmpty else { return }
        var combined = readings
        // If existing readings are purely simulated (288 readings and demoMode is on), replace with real readings
        if demoMode {
            combined = []
            demoMode = false
        }
        for r in incoming {
            if !combined.contains(where: { abs($0.timestamp.timeIntervalSince(r.timestamp)) < 90 && $0.mgdL == r.mgdL }) {
                combined.append(r)
            }
        }
        let cutoff = Date().addingTimeInterval(-36 * 3600)
        readings = combined
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func startDirectG7BLE() {
        UIApplication.shared.isIdleTimerDisabled = true
        bleScanElapsedSeconds = 0
        startFastBLECatchTimer()
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else if centralManager?.state == .poweredOn {
            pollConnectedG7Peripherals()
            centralManager?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            bleScanning = true
        }
    }

    private func startFastBLECatchTimer() {
        bleFastTimer?.invalidate()
        // Dexcom G7 only wakes its BLE radio for ~2 seconds every 5 minutes (300s).
        // Polling retrieveConnectedPeripherals every 1.5s guarantees we catch already-bonded
        // G7 sensors and Tandem t:slim X2 pumps during that 2-second window.
        bleFastTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.bleScanning {
                    self.bleScanElapsedSeconds += 2
                }
                self.pollConnectedG7Peripherals()
            }
        }
    }

    func pollConnectedG7Peripherals() {
        guard let central = centralManager, central.state == .poweredOn else { return }
        // 1. Check any Dexcom G7 or Tandem pump already connected at the iOS Bluetooth system level
        let connected = central.retrieveConnectedPeripherals(withServices: [
            Self.g7AdvServiceUUID,
            Self.g7CGMServiceUUID,
            Self.g7AltServiceUUID,
            Self.tandemServiceUUID1,
            Self.tandemServiceUUID2,
            Self.deviceInfoServiceUUID,
            Self.batteryServiceUUID
        ])
        for p in connected {
            let pName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = pName.uppercased()
            let isDexcom = upper.contains("DXCM") || upper.contains("DEXCOM") || upper.hasPrefix("DX")
            let isTandem = upper.contains("TSLIM") || upper.contains("T:SLIM") || upper.contains("TANDEM")
            if isDexcom || isTandem || showAllBLEDevices {
                let category = isTandem ? "Tandem t:slim X2 (Bonded)" : (isDexcom ? "Dexcom G7 (Bonded)" : "Connected BLE")
                upsertBLEDevice(
                    id: p.identifier.uuidString,
                    name: pName.isEmpty ? "Bonded G7 / Pump" : pName,
                    category: category,
                    rssi: -52
                )
            }
            if isDexcom || pName.isEmpty {
                attachAndConnectG7Peripheral(p, central: central)
            }
        }
        // 2. Check previously discovered G7 peripheral UUID so iOS auto-connects on its 5-min wake window
        if let savedStr = UserDefaults.standard.string(forKey: Self.savedG7UUIDKey),
           let uuid = UUID(uuidString: savedStr) {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            for p in known {
                attachAndConnectG7Peripheral(p, central: central)
            }
        }
    }

    func upsertBLEDevice(id: String, name: String, category: String, rssi: Int) {
        let dev = BLEPeripheralDevice(
            id: id,
            name: name,
            category: category,
            rssi: rssi,
            lastSeen: Date()
        )
        if let idx = bleDevices.firstIndex(where: { $0.id == id }) {
            bleDevices[idx] = dev
        } else {
            bleDevices.insert(dev, at: 0)
        }
    }

    func connectToBLEDevice(id: String) {
        guard let central = centralManager,
              let uuid = UUID(uuidString: id),
              let p = allDiscoveredPeripherals[uuid] ?? g7Peripherals[uuid] else { return }
        attachAndConnectG7Peripheral(p, central: central)
    }

    func attachAndConnectG7Peripheral(_ peripheral: CBPeripheral, central: CBCentralManager) {
        g7Peripherals[peripheral.identifier] = peripheral
        allDiscoveredPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedG7UUIDKey)
        let name = peripheral.name ?? "Dexcom G7"
        if g7BLEConnectedName.isEmpty || g7BLEConnectedName == "Dexcom G7" {
            g7BLEConnectedName = name
        }
        upsertBLEDevice(
            id: peripheral.identifier.uuidString,
            name: name,
            category: "Dexcom G7 (Target)",
            rssi: -55
        )
        if peripheral.state == .connected {
            g7BLEStatus = "Connected to \(name) · Reading G7 GATT…"
            peripheral.discoverServices(nil)
        } else if peripheral.state != .connecting {
            g7BLEStatus = "Locked onto \(name) · Waiting for 5-min G7 wake tick…"
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        }
    }

    func toggleBLEScan() {
        if bleScanning {
            centralManager?.stopScan()
            bleScanning = false
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            startDirectG7BLE()
        }
    }

    func uploadBLEReadingsToNightscout(_ newReadings: [GlucoseReading]) async {
        guard !newReadings.isEmpty,
              let url = URL(string: "\(truenasBridgeBaseURL)/api/ble-readings") else { return }
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = newReadings.map { r in
            let ms = Int64(r.timestamp.timeIntervalSince1970 * 1000.0)
            let dir: String
            switch r.trend {
            case .doubleUp: dir = "DoubleUp"
            case .singleUp: dir = "SingleUp"
            case .fortyFiveUp: dir = "FortyFiveUp"
            case .flat, .unknown: dir = "Flat"
            case .fortyFiveDown: dir = "FortyFiveDown"
            case .singleDown: dir = "SingleDown"
            case .doubleDown: dir = "DoubleDown"
            }
            return [
                "type": "sgv",
                "sgv": r.mgdL,
                "date": ms,
                "dateString": iso.string(from: r.timestamp),
                "direction": dir,
                "device": "DexcomG7-DirectBLE"
            ]
        }
        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            _ = try await URLSession.shared.data(for: req)
        } catch {}
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

extension GlucoStore: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let isOn = central.state == .poweredOn
        Task { @MainActor in
            if isOn {
                self.pollConnectedG7Peripherals()
                if self.g7DirectBLEEnabled || self.bleScanning {
                    central.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                    )
                    self.bleScanning = true
                    self.g7BLEStatus = "Scanning for Dexcom G7 (DXCM) & bonded sensors…"
                }
            } else {
                self.g7BLEStatus = "Bluetooth is off or unauthorized."
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rawName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        var serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDs.append(contentsOf: overflow)
        }
        if let solicited = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDs.append(contentsOf: solicited)
        }

        let hasG7Service = serviceUUIDs.contains(Self.g7AdvServiceUUID)
            || serviceUUIDs.contains(Self.g7CGMServiceUUID)
            || serviceUUIDs.contains(Self.g7AltServiceUUID)
        let hasTandemService = serviceUUIDs.contains(Self.tandemServiceUUID1)
            || serviceUUIDs.contains(Self.tandemServiceUUID2)

        // Check Bluetooth SIG Manufacturer Company ID: 0x00D0 (208) = Dexcom, Inc.
        var isDexcomMfg = false
        var mfgHex = ""
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 2 {
            let bytes = [UInt8](mfgData)
            let companyId = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            if companyId == 0x00D0 {
                isDexcomMfg = true
            }
            mfgHex = String(format: "0x%04X", companyId)
        }

        let upper = trimmed.uppercased()
        let isDexcom = hasG7Service || isDexcomMfg || upper.contains("DXCM") || upper.contains("DEXCOM") || upper.hasPrefix("DX0") || upper.hasPrefix("DXC") || upper.hasPrefix("DX")
        let isTandem = hasTandemService || upper.contains("TSLIM") || upper.contains("T:SLIM") || upper.contains("TANDEM")

        let rssiVal = RSSI.intValue
        let uuidStr = peripheral.identifier.uuidString
        let shortId = String(uuidStr.prefix(6))
        let svcSummary = serviceUUIDs.map { $0.uuidString.prefix(4) }.joined(separator: ",")

        Task { @MainActor in
            self.allDiscoveredPeripherals[peripheral.identifier] = peripheral
            guard isDexcom || isTandem || self.showAllBLEDevices else { return }

            let displayName: String
            if !trimmed.isEmpty {
                displayName = trimmed
            } else if isDexcom {
                displayName = "DXCM G7 (\(shortId))"
            } else if isTandem {
                displayName = "t:slim X2 (\(shortId))"
            } else {
                let extra = !mfgHex.isEmpty ? mfgHex : (!svcSummary.isEmpty ? String(svcSummary) : shortId)
                displayName = "BLE \(extra)"
            }

            let category = isDexcom ? "Dexcom G7" : (isTandem ? "Tandem t:slim X2" : "Nearby BLE")
            self.upsertBLEDevice(id: uuidStr, name: displayName, category: category, rssi: rssiVal)

            if isDexcom && self.g7DirectBLEEnabled {
                self.attachAndConnectG7Peripheral(peripheral, central: central)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "DXCMAK"
        peripheral.delegate = self
        peripheral.discoverServices([Self.g7CGMServiceUUID, Self.g7AdvServiceUUID])
        Task { @MainActor in
            self.g7BLEConnectedName = name
            UserDefaults.standard.set(name, forKey: Self.g7SensorNameKey)
            self.g7Authenticator.transmitterID = name
            self.g7Authenticator.pairingCode = self.g7PairingCode
            self.g7Authenticator.resetSession()
            self.g7WriteGeneration &+= 1
            self.g7AuthStreamBuffer.removeAll(keepingCapacity: true)
            self.g7PendingPakePhase = nil
            self.g7PendingCertPhase = nil
            self.g7PendingCertSize = nil
            self.g7ExpectedCertPhase = 0
            self.g7PendingProofChallenge = nil
            self.g7UsingFullBootstrap = false
            self.g7InitialPacketSent = false
            self.g7ChallengeResponseSent = false
            self.g7CertExchangeStarted = false
            self.g7BLEStatus = "Connected to \(name) · Discovering G7 GATT…"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "DXCMAK"
        Task { @MainActor in
            self.g7WriteGeneration &+= 1
            if self.g7DirectBLEEnabled {
                if self.g7BLEStatus.hasPrefix("Connected to ") || self.g7BLEStatus.hasPrefix("Scanning") {
                    if self.g7Authenticator.hasConfirmedSharedKey {
                        self.g7BLEStatus = "Paired with \(name) · Waiting for next 5-min G7 wake tick…"
                    } else if self.g7PairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.g7BLEStatus = "Found \(name)! Enter 4-digit G7 Pairing Code in Settings (Tandem Pump: Options → My CGM) for standalone BLE!"
                    } else {
                        self.g7BLEStatus = "Waiting for next 5-min G7 wake from \(name) to complete pairing…"
                    }
                }
                central.connect(peripheral, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([
                Self.g7AuthStreamCharUUID,
                Self.g7AuthCharUUID,
                Self.g7ControlCharUUID,
                Self.g7BackfillCharUUID,
                Self.g7ReadCharUUID
            ], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        Task { @MainActor in
            for ch in chars {
                switch ch.uuid {
                case Self.g7AuthStreamCharUUID:
                    self.g7AuthStreamChar = ch
                case Self.g7AuthCharUUID:
                    self.g7AuthChar = ch
                case Self.g7ControlCharUUID:
                    self.g7ControlChar = ch
                case Self.g7BackfillCharUUID:
                    self.g7BackfillChar = ch
                default:
                    break
                }
            }
            // Enable Auth_Stream first (if present) so J-PAKE fragments are never missed, then Receive_Authentication
            if let streamCh = self.g7AuthStreamChar, !streamCh.isNotifying {
                peripheral.setNotifyValue(true, for: streamCh)
            }
            if let authCh = self.g7AuthChar, !authCh.isNotifying {
                peripheral.setNotifyValue(true, for: authCh)
            }
            // If neither needs waiting or already notifying, kick off auth
            if (self.g7AuthStreamChar?.isNotifying ?? true) && (self.g7AuthChar?.isNotifying ?? false) {
                self.startG7AuthHandshakeIfNeeded(peripheral: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        Task { @MainActor in
            if uuid == Self.g7AuthStreamCharUUID && isNotifying {
                if let authCh = self.g7AuthChar, !authCh.isNotifying {
                    peripheral.setNotifyValue(true, for: authCh)
                } else if self.g7AuthChar?.isNotifying == true {
                    self.startG7AuthHandshakeIfNeeded(peripheral: peripheral)
                }
                return
            }
            if uuid == Self.g7AuthCharUUID && isNotifying {
                self.startG7AuthHandshakeIfNeeded(peripheral: peripheral)
                return
            }
            if uuid == Self.g7ControlCharUUID && isNotifying {
                // Request current G7 Glucose (0x4E) once control notifications are active after authentication
                let wType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(Data([0x4E]), for: characteristic, type: wType)
            }
        }
    }

    @MainActor
    private func startG7AuthHandshakeIfNeeded(peripheral: CBPeripheral) {
        guard !g7InitialPacketSent, let authCh = g7AuthChar else { return }
        if let initial = g7Authenticator.makeInitialControlPacket() {
            g7InitialPacketSent = true
            g7UsingFullBootstrap = initial.isFullBootstrap
            g7BLEStatus = initial.isFullBootstrap
                ? "G7 J-PAKE ownership pairing started with \(g7BLEConnectedName)…"
                : "G7 fast AES-128 auth started with \(g7BLEConnectedName)…"
            writeG7AuthControl(initial.packet, to: authCh, on: peripheral)
        } else {
            // No saved key and no 4-digit pairing code entered yet:
            // Listen passively for Coexistence mode AND send a slot-2 auth probe after 0.6s so we know sensor status
            g7InitialPacketSent = true
            if let ctrl = g7ControlChar, !ctrl.isNotifying {
                peripheral.setNotifyValue(true, for: ctrl)
            }
            g7BLEStatus = "Connected to \(g7BLEConnectedName) · Enter 4-digit G7 Pairing Code in Settings (Tandem Pump: Options → My CGM)!"
            let probe = g7Authenticator.makeAuthRequestPacket()
            writeG7AuthControl(probe, to: authCh, on: peripheral)
        }
    }

    @MainActor
    private func writeG7AuthControl(_ data: Data, to authCh: CBCharacteristic, on peripheral: CBPeripheral) {
        let wType: CBCharacteristicWriteType = authCh.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: authCh, type: wType)
    }

    @MainActor
    private func writeG7StreamExchange(streamPackets: [Data], controlPacket: Data, on peripheral: CBPeripheral) {
        guard let streamCh = g7AuthStreamChar, let authCh = g7AuthChar else { return }
        let gen = g7WriteGeneration
        let spacing: TimeInterval = 0.04
        for (idx, pkt) in streamPackets.enumerated() where !pkt.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(idx)) { [weak self] in
                guard let self, self.g7WriteGeneration == gen else { return }
                peripheral.writeValue(pkt, for: streamCh, type: .withoutResponse)
            }
        }
        let controlDelay = spacing * Double(streamPackets.count + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + controlDelay) { [weak self] in
            guard let self, self.g7WriteGeneration == gen else { return }
            self.writeG7AuthControl(controlPacket, to: authCh, on: peripheral)
        }
    }

    @MainActor
    private func onG7Authenticated(peripheral: CBPeripheral) {
        g7BLEStatus = "G7 Authenticated with \(g7BLEConnectedName) · Reading live CGM glucose…"
        if let bfCh = g7BackfillChar, !bfCh.isNotifying {
            peripheral.setNotifyValue(true, for: bfCh)
        }
        if let ctrlCh = g7ControlChar {
            if ctrlCh.isNotifying {
                let wType: CBCharacteristicWriteType = ctrlCh.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(Data([0x4E]), for: ctrlCh, type: wType)
            } else {
                peripheral.setNotifyValue(true, for: ctrlCh)
            }
        }
    }

    @MainActor
    private func processPendingG7AuthStreams(peripheral: CBPeripheral) {
        // 1. J-PAKE 160-byte phase payload
        if let phase = g7PendingPakePhase, g7AuthStreamBuffer.count >= 160 {
            let payload = Data(g7AuthStreamBuffer.prefix(160))
            g7AuthStreamBuffer.removeFirst(160)
            g7PendingPakePhase = nil
            if let res = g7Authenticator.handlePakePhase(phase, payload: payload) {
                g7BLEStatus = "G7 J-PAKE Phase \(phase + 1)/3 verified with \(g7BLEConnectedName)…"
                writeG7StreamExchange(streamPackets: res.streamPackets, controlPacket: res.controlPacket, on: peripheral)
            } else {
                g7BLEStatus = "G7 J-PAKE Phase \(phase) failed — check 4-digit G7 Pairing Code in Settings!"
            }
        }

        // 2. Certificate exchange payload
        if let phase = g7PendingCertPhase, let size = g7PendingCertSize, g7AuthStreamBuffer.count >= size {
            if size > 0 {
                g7AuthStreamBuffer.removeFirst(size)
            }
            g7PendingCertPhase = nil
            g7PendingCertSize = nil
            g7ExpectedCertPhase = phase &+ 1

            let packets = g7Authenticator.certificateStreamPackets(phase: phase)
            if phase < 2 {
                if let nextCtrl = g7Authenticator.certificateControlPacket(phase: phase + 1) {
                    g7BLEStatus = "G7 Certificate Phase \(phase + 1)/3 with \(g7BLEConnectedName)…"
                    writeG7StreamExchange(streamPackets: packets, controlPacket: nextCtrl, on: peripheral)
                }
            } else if let authCh = g7AuthChar {
                g7BLEStatus = "G7 Proof-of-Possession challenge with \(g7BLEConnectedName)…"
                let popReq = g7Authenticator.makeProofOfPossessionChallengeRequest()
                writeG7AuthControl(popReq, to: authCh, on: peripheral)
            }
        }

        // 3. Proof-of-Possession 64-byte remote signature
        if let challenge = g7PendingProofChallenge, g7AuthStreamBuffer.count >= 64 {
            g7AuthStreamBuffer.removeFirst(64)
            g7PendingProofChallenge = nil
            if let popResp = g7Authenticator.makeProofOfPossessionResponse(challenge: challenge) {
                g7BLEStatus = "G7 Ownership Proof signed · Confirming with \(g7BLEConnectedName)…"
                writeG7StreamExchange(streamPackets: popResp.streamPackets, controlPacket: popResp.controlPacket, on: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let charUUID = characteristic.uuid
        let bytes = [UInt8](data)

        if charUUID == Self.g7AuthStreamCharUUID {
            Task { @MainActor in
                self.g7AuthStreamBuffer.append(data)
                self.processPendingG7AuthStreams(peripheral: peripheral)
            }
            return
        }

        if charUUID == Self.g7AuthCharUUID {
            Task { @MainActor in
                guard let authCh = self.g7AuthChar else { return }
                let op = bytes[0]

                switch op {
                case 0x03: // AuthRequestRx (17 bytes: 0x03 + 8B tokenHash + 8B challenge)
                    guard !self.g7ChallengeResponseSent, data.count >= 17 else { return }
                    let challenge = data.subdata(in: 9..<17)
                    if let resp = self.g7Authenticator.makeChallengeResponse(challenge: challenge) {
                        self.g7ChallengeResponseSent = true
                        self.g7BLEStatus = "G7 AES-128 challenge answered for \(self.g7BLEConnectedName)…"
                        self.writeG7AuthControl(resp, to: authCh, on: peripheral)
                    } else {
                        self.g7BLEStatus = "\(self.g7BLEConnectedName) requested auth — enter 4-digit G7 Pairing Code in Settings (Tandem Pump: Options → My CGM)!"
                    }

                case 0x05: // AuthChallengeRx / AuthStatusRx (0x05, isAuthenticated, isPaired)
                    guard bytes.count >= 3 else { return }
                    let isAuth = bytes[1] == 0x01
                    let isPaired = bytes[2] == 0x01
                    if isAuth {
                        if self.g7UsingFullBootstrap {
                            if !self.g7CertExchangeStarted {
                                self.g7CertExchangeStarted = true
                                self.g7ExpectedCertPhase = 0
                                self.g7AuthStreamBuffer.removeAll(keepingCapacity: true)
                                if let cert0 = self.g7Authenticator.certificateControlPacket(phase: 0) {
                                    self.g7BLEStatus = "G7 J-PAKE verified · Exchanging certificates with \(self.g7BLEConnectedName)…"
                                    self.writeG7AuthControl(cert0, to: authCh, on: peripheral)
                                }
                            }
                        } else if isPaired {
                            self.onG7Authenticated(peripheral: peripheral)
                        } else {
                            // Authenticated but unpaired -> clear partial key so next packet runs full bootstrap
                            self.g7Authenticator.clearSharedKey()
                            self.g7BLEStatus = "G7 slot needs full bootstrap — reconnecting \(self.g7BLEConnectedName)…"
                        }
                    } else {
                        self.g7BLEStatus = "\(self.g7BLEConnectedName) unauthenticated — enter 4-digit G7 Pairing Code in Settings (from Tandem Pump: Options → My CGM)!"
                    }

                case 0x0A: // ExchangePakePayload (0x0A, 0x00, phase)
                    guard bytes.count >= 3, bytes[1] == 0x00 else {
                        self.g7BLEStatus = "G7 rejected J-PAKE — check 4-digit Pairing Code in Settings!"
                        return
                    }
                    self.g7PendingPakePhase = bytes[2]
                    self.processPendingG7AuthStreams(peripheral: peripheral)

                case 0x0B: // CertificateExchange (0x0B, 0x00, phase, sizeLE[4])
                    guard bytes.count >= 7, bytes[1] == 0x00 else { return }
                    let phase = bytes[2]
                    let size = Int(UInt32(bytes[3]) | (UInt32(bytes[4]) << 8) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 24))
                    guard size <= 4096 else { return }
                    self.g7PendingCertPhase = phase
                    self.g7PendingCertSize = size
                    self.processPendingG7AuthStreams(peripheral: peripheral)

                case 0x0C: // ProofOfPossession (0x0C, 0x00, challenge[16])
                    guard data.count >= 18, bytes[1] == 0x00 else { return }
                    self.g7PendingProofChallenge = data.subdata(in: 2..<18)
                    self.processPendingG7AuthStreams(peripheral: peripheral)

                case 0x0D: // AuthStatusTx ack -> send keep-alive 0x06 0x19
                    self.writeG7AuthControl(Data([0x06, 0x19]), to: authCh, on: peripheral)

                case 0x06: // KeepAlive response (0x06 0x01 = complete, 0x06 0x00 = request bond 0x07)
                    if bytes.count >= 2 && bytes[1] == 0x01 {
                        self.g7Authenticator.confirmAndPersistSharedKey()
                        self.onG7Authenticated(peripheral: peripheral)
                    } else if bytes.count >= 2 && bytes[1] == 0x00 {
                        self.g7BLEStatus = "G7 requesting iOS Bluetooth Bond — tap 'Pair' if prompted!"
                        self.writeG7AuthControl(Data([0x07]), to: authCh, on: peripheral)
                    }

                case 0x08: // PairRequestRx (0x08 0x01 = bonded!)
                    if bytes.count >= 2 && bytes[1] == 0x01 {
                        self.g7Authenticator.confirmAndPersistSharedKey()
                        self.onG7Authenticated(peripheral: peripheral)
                    }

                default:
                    break
                }
            }
            return
        }

        if charUUID == Self.g7ControlCharUUID {
            // Support BOTH Opcode 0x4E (Primary G7GlucoseMessage, 16+ bytes) AND Opcode 0x31 (G7CoexistenceGlucoseMessage, 14+ bytes)
            var parsedMgdL: Int?
            var parsedMsgTs: UInt32 = 0
            var parsedAgeSec: UInt16 = 0
            var parsedRawTrend: Int8 = 0

            if bytes[0] == 0x4E && bytes.count >= 16 && bytes[1] == 0x00 {
                let rawGlucose = UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
                if rawGlucose != 0xFFFF {
                    parsedMgdL = Int(rawGlucose & 0x0FFF)
                    parsedMsgTs = UInt32(bytes[2]) | (UInt32(bytes[3]) << 8) | (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 24)
                    parsedAgeSec = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
                    parsedRawTrend = Int8(bitPattern: bytes[15])
                }
            } else if bytes[0] == 0x31 && bytes.count >= 14 && bytes[1] == 0x00 {
                let rawGlucose = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
                if rawGlucose != 0xFFFF {
                    parsedMgdL = Int(rawGlucose & 0x0FFF)
                    parsedMsgTs = UInt32(bytes[6]) | (UInt32(bytes[7]) << 8) | (UInt32(bytes[8]) << 16) | (UInt32(bytes[9]) << 24)
                    parsedAgeSec = 0
                    parsedRawTrend = Int8(bitPattern: bytes[13])
                }
            }

            if let mgdL = parsedMgdL, (20...500).contains(mgdL) {
                let trend = Self.trendFromG7Rate(parsedRawTrend)
                let readingDate = Date().addingTimeInterval(-Double(min(parsedAgeSec, 1800)))
                let reading = GlucoseReading(mgdL: mgdL, timestamp: readingDate, trend: trend)
                let msgTs = parsedMsgTs

                if msgTs > 3600 {
                    let startTs = msgTs > 21600 ? (msgTs - 21600) : 0
                    let endTs = msgTs
                    var bfCmd: [UInt8] = [0x59]
                    bfCmd.append(contentsOf: withUnsafeBytes(of: startTs.littleEndian, Array.init))
                    bfCmd.append(contentsOf: withUnsafeBytes(of: endTs.littleEndian, Array.init))
                    let wType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                    peripheral.writeValue(Data(bfCmd), for: characteristic, type: wType)
                }

                Task { @MainActor in
                    self.g7LastSensorTimestamp = msgTs
                    self.lastBLEGlucoseDate = readingDate
                    self.dexcomConnected = true
                    self.demoMode = false
                    self.mergeReadings([reading])
                    self.g7BLEStatus = "Live G7 BLE (\(self.g7BLEConnectedName)) · \(self.formatGlucose(mgdL)) \(self.unit.rawValue) \(trend.arrow) (\(Self.shortTime(readingDate)))"
                    self.statusBanner = "Direct G7 Bluetooth LE · \(self.formatGlucose(mgdL)) \(self.unit.rawValue) \(trend.arrow) · \(Self.shortTime(Date()))"
                    self.checkGlucoseAlerts()
                    await self.uploadBLEReadingsToNightscout([reading])
                }
            }
            return
        }

        if charUUID == Self.g7BackfillCharUUID && bytes.count >= 9 {
            let sensorTs = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let rawGlucose = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
            guard rawGlucose != 0xffff else { return }
            let mgdL = Int(rawGlucose & 0x0fff)
            guard (20...500).contains(mgdL) else { return }
            let rawTrend = Int8(bitPattern: bytes[7])
            let trend = Self.trendFromG7Rate(rawTrend)

            Task { @MainActor in
                guard self.g7LastSensorTimestamp > 0, sensorTs <= self.g7LastSensorTimestamp else { return }
                let ageSec = Double(self.g7LastSensorTimestamp - sensorTs)
                let baseDate = self.lastBLEGlucoseDate ?? Date()
                let readingDate = baseDate.addingTimeInterval(-ageSec)
                let reading = GlucoseReading(mgdL: mgdL, timestamp: readingDate, trend: trend)
                self.mergeReadings([reading])
                await self.uploadBLEReadingsToNightscout([reading])
            }
        }
    }

    nonisolated private static func trendFromG7Rate(_ rawTrend: Int8) -> GlucoseTrend {
        if rawTrend == Int8.min || rawTrend == Int8.max { return .flat }
        let rate = Double(rawTrend) / 10.0
        if rate >= 3.0 { return .doubleUp }
        if rate >= 2.0 { return .singleUp }
        if rate >= 1.0 { return .fortyFiveUp }
        if rate <= -3.0 { return .doubleDown }
        if rate <= -2.0 { return .singleDown }
        if rate <= -1.0 { return .fortyFiveDown }
        return .flat
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
