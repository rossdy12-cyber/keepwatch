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
    var iobUnits: Double = 0.0
    var cobGrams: Int = 0
    var activeBasalRate: Double = 0.0
    var scheduledBasalRate: Double = 0.0
    var batteryPercent: Int = 0
    var reservoirUnits: Double = 0.0
    var controlIQMode: String = "Waiting for t:slim X2 / G7 BLE"
    var lastBolusUnits: Double = 0.0
    var lastBolusDate: Date = Date.distantPast
    var lastSyncDate: Date = Date.distantPast
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

    // Persistent UserDefaults keys (v3 live-only keys so stale demo data is never restored)
    private static let unitKey = "gluco.unit"
    private static let lowMgdLKey = "gluco.lowMgdL"
    private static let highMgdLKey = "gluco.highMgdL"
    private static let urgentLowMgdLKey = "gluco.urgentLowMgdL"
    private static let dexcomUserKey = "gluco.dexcomUser"
    private static let dexcomPassKey = "gluco.dexcomPass"
    private static let dexcomRegionKey = "gluco.dexcomRegion"
    private static let nightscoutURLKey = "gluco.nightscoutURL"
    private static let nightscoutTokenKey = "gluco.nightscoutToken"
    private static let demoModeKey = "gluco.demoMode.v3"
    private static let readingsKey = "gluco.readings.live.v3"
    private static let pumpStatusKey = "gluco.pumpStatus.live.v3"
    private static let pumpEventsKey = "gluco.pumpEvents.live.v3"
    private static let tandemEmailKey = "gluco.tandemEmail"
    private static let tandemPassKey = "gluco.tandemPass"
    private static let tandemRegionKey = "gluco.tandemRegion"
    private static let tandemSerialKey = "gluco.tandemSerial"
    private static let g7DirectBLEKey = "gluco.g7DirectBLE"
    private static let savedG7UUIDKey = "gluco.savedG7UUID.v5"
    private static let savedTandemUUIDKey = "gluco.savedTandemUUID.v5"
    private static let g7PairingCodeKey = "gluco.g7PairingCode"
    private static let g7SensorNameKey = "gluco.g7SensorName"
    private static let tandemPairingCodeKey = "gluco.tandemPairingCode"
    private static let alertsEnabledKey = "gluco.alertsEnabled"
    private static let highAlertsEnabledKey = "gluco.highAlertsEnabled"
    private static let highAlertRepeatMinutesKey = "gluco.highAlertRepeatMinutes"
    private static let alertSnoozedUntilKey = "gluco.alertSnoozedUntil"
    private static let lastAlertBandKey = "gluco.lastAlertBand"
    private static let lastHighAlertAtKey = "gluco.lastHighAlertAt"
    private static let lastLowAlertAtKey = "gluco.lastLowAlertAt"
    private static let lastUrgentLowAlertAtKey = "gluco.lastUrgentLowAlertAt"

    // Dexcom G7 & Tandem GATT Service & Characteristic UUIDs (LoopKit / G7SensorKit / jwoglom pumpX2 spec)
    nonisolated static let g7AdvServiceUUID = CBUUID(string: "FEBC")
    nonisolated static let g7CGMServiceUUID = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7AltServiceUUID = CBUUID(string: "F8084532-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7ReadCharUUID = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7ControlCharUUID = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7AuthCharUUID = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7BackfillCharUUID = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
    nonisolated static let g7AuthStreamCharUUID = CBUUID(string: "F8083538-849E-531C-C594-30F1F86A4EA5")

    // Tandem t:slim X2 / Mobi BLE Service & Characteristic UUIDs
    nonisolated static let tandemServiceUUID1 = CBUUID(string: "FDFB")
    nonisolated static let tandemFullServiceUUID = CBUUID(string: "0000FDFB-0000-1000-8000-00805F9B34FB")
    nonisolated static let tandemTDUServiceUUID = CBUUID(string: "FDFA")
    nonisolated static let tandemServiceUUID2 = CBUUID(string: "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let tandemCurrentStatusCharUUID = CBUUID(string: "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let tandemQualifyingEventsCharUUID = CBUUID(string: "7B83FFF7-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let tandemHistoryLogCharUUID = CBUUID(string: "7B83FFF8-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let tandemAuthCharUUID = CBUUID(string: "7B83FFF9-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let tandemControlCharUUID = CBUUID(string: "7B83FFFC-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let tandemControlStreamCharUUID = CBUUID(string: "7B83FFFD-9F77-4E5C-8064-AAE2C24838B9")
    nonisolated static let deviceInfoServiceUUID = CBUUID(string: "180A")
    nonisolated static let disManufacturerCharUUID = CBUUID(string: "2A29")
    nonisolated static let disModelNumberCharUUID = CBUUID(string: "2A24")
    nonisolated static let disSerialNumberCharUUID = CBUUID(string: "2A25")
    nonisolated static let disSoftwareRevCharUUID = CBUUID(string: "2A28")
    nonisolated static let batteryServiceUUID = CBUUID(string: "180F")
    nonisolated static let batteryLevelCharUUID = CBUUID(string: "2A19")

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
    @Published var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsEnabledKey)
            if !alertsEnabled {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
    }
    @Published var highAlertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(highAlertsEnabled, forKey: Self.highAlertsEnabledKey)
            if !highAlertsEnabled {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["gluco.alert"])
            }
        }
    }
    @Published var highAlertRepeatMinutes: Int {
        didSet { UserDefaults.standard.set(highAlertRepeatMinutes, forKey: Self.highAlertRepeatMinutesKey) }
    }
    @Published var alertSnoozedUntil: Date {
        didSet { UserDefaults.standard.set(alertSnoozedUntil.timeIntervalSince1970, forKey: Self.alertSnoozedUntilKey) }
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
            if demoMode {
                loadSimulatedData()
                statusBanner = "Demo Telemetry Active · Turn off Demo Mode for live G7 / t:slim X2"
            } else {
                clearSimulatedData()
                statusBanner = "Live Mode · Listening for G7 BLE & Tandem t:slim X2…"
                Task { await refreshAll() }
            }
        }
    }

    @Published var readings: [GlucoseReading] = [] {
        didSet {
            guard !isShowingSimulatedData else { return }
            if let data = try? JSONEncoder().encode(readings) {
                UserDefaults.standard.set(data, forKey: Self.readingsKey)
            }
        }
    }
    @Published var pumpStatus: TandemPumpStatus {
        didSet {
            guard !isShowingSimulatedData else { return }
            if let data = try? JSONEncoder().encode(pumpStatus) {
                UserDefaults.standard.set(data, forKey: Self.pumpStatusKey)
            }
        }
    }
    @Published var pumpEvents: [PumpEvent] {
        didSet {
            guard !isShowingSimulatedData else { return }
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
            if trimmed.count >= 4 {
                g7InitialPacketSent = false
                g7ChallengeResponseSent = false
                for (_, p) in g7Peripherals where p.state == .connected {
                    startG7AuthHandshakeIfNeeded(peripheral: p)
                }
            }
        }
    }
    @Published var tandemPairingCode: String {
        didSet {
            let trimmed = tandemPairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: Self.tandemPairingCodeKey)
            tandemAuthenticator.pairingCode = trimmed
            let clean = tandemAuthenticator.cleanPairingCode
            if clean.count == 6 || clean.count == 16 {
                tandemNeedsPairingCode = false
                submitTandemPairingCode()
            }
        }
    }

    @Published var tandemNeedsPairingCode: Bool = false
    @Published var isSyncing: Bool = false
    @Published var dexcomConnected: Bool = false
    @Published var dexcomDiagnostic: String = ""
    @Published var tandemConnected: Bool = false
    @Published var tandemDiagnostic: String = ""
    @Published var statusBanner: String = "Standalone G7 BLE + Tandem t:slim X2 · No Dexcom App Needed"
    @Published var bleDevices: [BLEPeripheralDevice] = []
    @Published var bleScanning: Bool = false
    @Published var showAllBLEDevices: Bool = false {
        didSet { Self.showAllBLENonisolated = showAllBLEDevices }
    }
    @Published var bleScanElapsedSeconds: Int = 0
    private static let bleQueue = DispatchQueue(label: "com.ross.glucopulse.ble", qos: .utility)
    nonisolated(unsafe) private static var showAllBLENonisolated: Bool = false
    @Published var g7BLEStatus: String = "Listening for Dexcom G7 (DXCMAK · Code 8222) 5-min wake pulse…"
    @Published var tandemBLEStatus: String = "Connecting to Tandem t:slim X2 over Bluetooth LE…"
    @Published var g7BLEConnectedName: String = "DXCMAK"
    @Published var lastBLEGlucoseDate: Date?

    private var isShowingSimulatedData: Bool = false
    private var dexcomSessionID: String?
    private var refreshTimer: Timer?
    private var bleFastTimer: Timer?
    private var centralManager: CBCentralManager?
    private var g7Peripherals: [UUID: CBPeripheral] = [:]
    private var tandemPeripherals: [UUID: CBPeripheral] = [:]
    private var allDiscoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredServicePeripherals: Set<UUID> = []
    private var lastTandemPollAt: [UUID: Date] = [:]
    private var lastTandemConnectAttemptAt: [UUID: Date] = [:]
    private var tandemTxId: UInt8 = 0
    private var tandemPacketBuffers: [UInt8: [UInt8]] = [:]
    private var tandemAuthPacketBuffers: [UInt8: [UInt8]] = [:]
    private var tandemCurrentStatusChar: CBCharacteristic?
    private var tandemQualifyingEventsChar: CBCharacteristic?
    private var tandemHistoryLogChar: CBCharacteristic?
    private var tandemAuthChar: CBCharacteristic?
    private var tandemControlChar: CBCharacteristic?
    private var tandemControlStreamChar: CBCharacteristic?
    private var pendingTandemNotifyUUIDs: Set<CBUUID> = []
    private var tandemGattReady: Bool = false
    private var tandemRequestQueue: [UInt8] = []
    private var tandemRequestInFlight: Bool = false
    private var tandemRequestGeneration: UInt64 = 0
    private var tandemTxMismatchRetries: Int = 0
    private var tandemRepliesReceivedCount: Int = 0
    private var tandemAuthInProgress: Bool = false
    private let tandemAuthenticator = TandemPumpNativeAuthenticator()
    private var g7LastSensorTimestamp: UInt32 = 0
    private var lastTandemCGMTimestampRaw: UInt32 = 0
    private var lastTandemCGMMgdL: Int = 0
    private var lastAlertBand: String = "normal"
    private var lastHighAlertAt: Date = .distantPast
    private var lastLowAlertAt: Date = .distantPast
    private var lastUrgentLowAlertAt: Date = .distantPast

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
        // Wipe legacy v1-v4 demo/UUID cache keys if present
        d.removeObject(forKey: "gluco.pumpStatus")
        d.removeObject(forKey: "gluco.pumpEvents")
        d.removeObject(forKey: "gluco.savedG7UUID")
        d.removeObject(forKey: "gluco.savedG7UUID.v3")

        unit = GlucoseUnit(rawValue: d.string(forKey: Self.unitKey) ?? "") ?? .mmolL
        lowMgdL = d.object(forKey: Self.lowMgdLKey) as? Int ?? 70      // 3.9 mmol/L
        highMgdL = d.object(forKey: Self.highMgdLKey) as? Int ?? 198    // 11.0 mmol/L default
        urgentLowMgdL = d.object(forKey: Self.urgentLowMgdLKey) as? Int ?? 54 // 3.0 mmol/L
        alertsEnabled = d.object(forKey: Self.alertsEnabledKey) as? Bool ?? true
        highAlertsEnabled = d.object(forKey: Self.highAlertsEnabledKey) as? Bool ?? true
        highAlertRepeatMinutes = d.object(forKey: Self.highAlertRepeatMinutesKey) as? Int ?? 60
        let snoozeEpoch = d.double(forKey: Self.alertSnoozedUntilKey)
        alertSnoozedUntil = snoozeEpoch > 0 ? Date(timeIntervalSince1970: snoozeEpoch) : .distantPast
        lastAlertBand = d.string(forKey: Self.lastAlertBandKey) ?? "normal"
        let highEpoch = d.double(forKey: Self.lastHighAlertAtKey)
        lastHighAlertAt = highEpoch > 0 ? Date(timeIntervalSince1970: highEpoch) : .distantPast
        let lowEpoch = d.double(forKey: Self.lastLowAlertAtKey)
        lastLowAlertAt = lowEpoch > 0 ? Date(timeIntervalSince1970: lowEpoch) : .distantPast
        let urgEpoch = d.double(forKey: Self.lastUrgentLowAlertAtKey)
        lastUrgentLowAlertAt = urgEpoch > 0 ? Date(timeIntervalSince1970: urgEpoch) : .distantPast

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
        let rawSavedG7Code = (d.string(forKey: Self.g7PairingCodeKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let savedCode = rawSavedG7Code.isEmpty ? "8222" : rawSavedG7Code
        g7PairingCode = savedCode
        let savedTandemCode = d.string(forKey: Self.tandemPairingCodeKey) ?? ""
        tandemPairingCode = savedTandemCode
        let savedSensorName = d.string(forKey: Self.g7SensorNameKey) ?? "DXCMAK"
        g7BLEConnectedName = savedSensorName

        // Default demoMode to false so fake data is NEVER shown unless explicitly enabled
        let isDemo = d.object(forKey: Self.demoModeKey) as? Bool ?? false
        demoMode = isDemo

        if !isDemo,
           let savedReadings = d.data(forKey: Self.readingsKey),
           let decodedReadings = try? JSONDecoder().decode([GlucoseReading].self, from: savedReadings) {
            readings = decodedReadings
        } else {
            readings = []
        }

        if !isDemo,
           let savedPump = d.data(forKey: Self.pumpStatusKey),
           let decoded = try? JSONDecoder().decode(TandemPumpStatus.self, from: savedPump) {
            pumpStatus = decoded
        } else {
            pumpStatus = TandemPumpStatus()
        }

        if !isDemo,
           let savedEvents = d.data(forKey: Self.pumpEventsKey),
           let decoded = try? JSONDecoder().decode([PumpEvent].self, from: savedEvents) {
            pumpEvents = decoded
        } else {
            pumpEvents = []
        }

        super.init()

        g7Authenticator.transmitterID = savedSensorName
        g7Authenticator.pairingCode = savedCode
        g7Authenticator.restorePersistedSharedKey()
        tandemAuthenticator.pairingCode = savedTandemCode

        if demoMode {
            loadSimulatedData()
        } else {
            clearSimulatedData()
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

    var isAlertSnoozed: Bool {
        Date() < alertSnoozedUntil
    }

    func snoozeAlerts(minutes: Int = 60) {
        alertSnoozedUntil = Date().addingTimeInterval(Double(minutes * 60))
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["gluco.alert"])
    }

    func clearAlertSnooze() {
        alertSnoozedUntil = .distantPast
    }

    func readings(inLastHours hours: Int) -> [GlucoseReading] {
        let cutoff = Date().addingTimeInterval(Double(-hours * 3600))
        let subset = readings.filter { $0.timestamp >= cutoff }
        return subset.isEmpty ? readings : subset
    }

    func timeInRangePercent(hours: Int) -> Int {
        let pool = readings(inLastHours: hours)
        guard !pool.isEmpty else { return 0 }
        let inRange = pool.filter { $0.mgdL >= lowMgdL && $0.mgdL <= highMgdL }.count
        return Int((Double(inRange) / Double(pool.count) * 100.0).rounded())
    }

    func timeBelowRangePercent(hours: Int) -> Int {
        let pool = readings(inLastHours: hours)
        guard !pool.isEmpty else { return 0 }
        let low = pool.filter { $0.mgdL < lowMgdL }.count
        return Int((Double(low) / Double(pool.count) * 100.0).rounded())
    }

    func timeAboveRangePercent(hours: Int) -> Int {
        let pool = readings(inLastHours: hours)
        guard !pool.isEmpty else { return 0 }
        return max(0, 100 - timeInRangePercent(hours: hours) - timeBelowRangePercent(hours: hours))
    }

    func averageMgdL(hours: Int) -> Int {
        let pool = readings(inLastHours: hours)
        guard !pool.isEmpty else { return 0 }
        let sum = pool.reduce(0) { $0 + $1.mgdL }
        return Int((Double(sum) / Double(pool.count)).rounded())
    }

    func gmiPercent(hours: Int) -> String {
        let pool = readings(inLastHours: hours)
        guard !pool.isEmpty else { return "--%" }
        let gmi = 3.31 + 0.02392 * Double(averageMgdL(hours: hours))
        return String(format: "%.1f%%", gmi)
    }

    var timeInRangePercent: Int { timeInRangePercent(hours: 24) }
    var timeBelowRangePercent: Int { timeBelowRangePercent(hours: 24) }
    var timeAboveRangePercent: Int { timeAboveRangePercent(hours: 24) }
    var averageMgdL: Int { averageMgdL(hours: 24) }
    var gmiPercent: String { gmiPercent(hours: 24) }

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

        if !demoMode && isShowingSimulatedData {
            clearSimulatedData()
        }

        // Also trigger direct BLE status request on any connected Tandem pump or G7 sensor
        for (_, p) in tandemPeripherals where p.state == .connected {
            requestTandemLiveStatus(on: p)
        }
        for (_, p) in g7Peripherals where p.state == .connected {
            startG7AuthHandshakeIfNeeded(peripheral: p)
        }

        var fetchedAnyLive = false

        if !dexcomUsername.trimmingCharacters(in: .whitespaces).isEmpty && !dexcomPassword.isEmpty {
            let ok = await syncDexcomShare()
            dexcomConnected = ok
            if ok { fetchedAnyLive = true }
        }

        if !nightscoutURL.trimmingCharacters(in: .whitespaces).isEmpty {
            let ok = await syncNightscout()
            tandemConnected = ok || tandemConnected
            if ok { fetchedAnyLive = true }
        }

        if demoMode && !fetchedAnyLive && readings.isEmpty {
            loadSimulatedData()
            statusBanner = "Demo Telemetry Active · Turn off Demo Mode in Settings for live G7 / t:slim X2"
        } else if fetchedAnyLive || lastBLEGlucoseDate != nil || tandemConnected {
            statusBanner = "Live Telemetry · Updated \(Self.shortTime(Date()))"
            if fetchedAnyLive {
                checkGlucoseAlerts()
            }
        } else if !demoMode {
            statusBanner = "Live Mode · Waiting for G7 BLE / Tandem t:slim X2 data…"
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

    // MARK: - 3. Direct Dexcom G7 + Tandem t:slim X2 Bluetooth LE GATT Reader (No Dexcom App Needed)

    func mergeReadings(_ incoming: [GlucoseReading]) {
        guard !incoming.isEmpty else { return }
        var combined = readings
        if isShowingSimulatedData || demoMode {
            isShowingSimulatedData = false
            combined = []
            if demoMode { demoMode = false }
        }
        for r in incoming {
            let isDuplicate = combined.contains { existing in
                let dt = abs(existing.timestamp.timeIntervalSince(r.timestamp))
                return (dt < 90) || (dt < 240 && existing.mgdL == r.mgdL)
            }
            if !isDuplicate {
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
            centralManager = CBCentralManager(delegate: self, queue: Self.bleQueue)
        } else if centralManager?.state == .poweredOn {
            pollConnectedG7Peripherals()
            let targetUUIDs: [CBUUID]? = showAllBLEDevices ? nil : [
                Self.g7AdvServiceUUID, Self.g7CGMServiceUUID, Self.g7AltServiceUUID,
                Self.tandemServiceUUID1, Self.tandemFullServiceUUID, Self.tandemTDUServiceUUID, Self.tandemServiceUUID2
            ]
            centralManager?.scanForPeripherals(
                withServices: targetUUIDs,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            if !bleScanning { bleScanning = true }
        }
    }

    func submitTandemPairingCode() {
        let trimmed = tandemPairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: Self.tandemPairingCodeKey)
        tandemAuthenticator.pairingCode = trimmed
        tandemAuthenticator.resetSession(clearPersistedSecret: true)
        tandemNeedsPairingCode = false
        lastTandemConnectAttemptAt.removeAll()

        guard let central = centralManager else {
            startDirectG7BLE()
            return
        }
        var foundAny = false
        for (_, p) in tandemPeripherals {
            foundAny = true
            if p.state == .connected {
                if tandemAuthChar != nil {
                    startTandemBLEAuth(on: p)
                } else {
                    p.discoverServices(nil)
                }
            } else {
                tandemBLEStatus = "Connecting to \(p.name ?? "t:slim X2") to pair with code \(tandemAuthenticator.cleanPairingCode)…"
                central.connect(p, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
        }
        if !foundAny {
            pollConnectedG7Peripherals()
        }
    }

    func forceBLEPollNow() {
        discoveredServicePeripherals.removeAll()
        lastTandemPollAt.removeAll()
        lastTandemConnectAttemptAt.removeAll()
        g7InitialPacketSent = false
        g7ChallengeResponseSent = false
        tandemTxMismatchRetries = 0
        startDirectG7BLE()
        pollConnectedG7Peripherals()
        for (_, p) in tandemPeripherals where p.state == .connected {
            tandemBLEStatus = "Re-discovering Tandem GATT services & polling live status…"
            if tandemCurrentStatusChar != nil && tandemAuthChar != nil {
                if tandemAuthenticator.hasCredentialsOrSecret && !tandemAuthenticator.isAuthenticated {
                    startTandemBLEAuth(on: p)
                } else {
                    requestTandemLiveStatus(on: p)
                }
            } else {
                p.discoverServices(nil)
            }
        }
        for (_, p) in g7Peripherals where p.state == .connected {
            g7BLEStatus = "Re-discovering G7 GATT services on \(g7BLEConnectedName)…"
            p.discoverServices(nil)
            startG7AuthHandshakeIfNeeded(peripheral: p)
        }
    }

    private func startFastBLECatchTimer() {
        bleFastTimer?.invalidate()
        bleFastTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.bleScanning && self.showAllBLEDevices {
                    self.bleScanElapsedSeconds += 25
                }
                self.pollConnectedG7Peripherals()
            }
        }
    }

    nonisolated private static func isDexcomName(_ name: String) -> Bool {
        let upper = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return false }
        return upper.contains("DXCM") || upper.contains("DEXCOM") || upper.hasPrefix("DX0") || upper.hasPrefix("DXC") || (upper.hasPrefix("DX") && upper.count == 6)
    }

    nonisolated private static func isTandemName(_ name: String) -> Bool {
        let upper = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return false }
        return upper.contains("TSLIM") || upper.contains("T:SLIM") || upper.contains("TANDEM") || upper.contains("MOBI")
    }

    /// Always preserves the existing CBPeripheral instance so CoreBluetooth never cancels in-flight GATT discovery or pending connections.
    private func canonicalPeripheral(_ p: CBPeripheral) -> CBPeripheral {
        if let existing = g7Peripherals[p.identifier] ?? tandemPeripherals[p.identifier] ?? allDiscoveredPeripherals[p.identifier] {
            existing.delegate = self
            return existing
        }
        p.delegate = self
        allDiscoveredPeripherals[p.identifier] = p
        return p
    }

    func pollConnectedG7Peripherals() {
        guard let central = centralManager else { return }
        let savedTandemStr = UserDefaults.standard.string(forKey: Self.savedTandemUUIDKey)
        let savedG7Str = UserDefaults.standard.string(forKey: Self.savedG7UUIDKey)

        // Query bluetoothd XPC on the background BLE queue so @MainActor (UI/scroll thread) never stalls
        Self.bleQueue.async { [weak self] in
            guard central.state == .poweredOn else { return }
            let connectedG7 = central.retrieveConnectedPeripherals(withServices: [
                Self.g7AdvServiceUUID,
                Self.g7CGMServiceUUID,
                Self.g7AltServiceUUID
            ])
            let connectedTandem = central.retrieveConnectedPeripherals(withServices: [
                Self.tandemServiceUUID1,
                Self.tandemFullServiceUUID,
                Self.tandemTDUServiceUUID,
                Self.tandemServiceUUID2
            ])
            let connectedGeneric = central.retrieveConnectedPeripherals(withServices: [
                Self.deviceInfoServiceUUID,
                Self.batteryServiceUUID
            ])
            var retrievedG7ById: [CBPeripheral] = []
            if let savedG7Str, savedG7Str != savedTandemStr, let uuid = UUID(uuidString: savedG7Str) {
                retrievedG7ById = central.retrievePeripherals(withIdentifiers: [uuid])
            }
            var retrievedTandemById: [CBPeripheral] = []
            if let savedTandemStr, let uuid = UUID(uuidString: savedTandemStr) {
                retrievedTandemById = central.retrievePeripherals(withIdentifiers: [uuid])
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for rawP in connectedG7 {
                    let p = self.canonicalPeripheral(rawP)
                    let pName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Self.isTandemName(pName) else { continue }
                    let displayName = pName.isEmpty ? "DXCMAK" : pName
                    self.upsertBLEDevice(id: p.identifier.uuidString, name: displayName, category: "Dexcom G7 (Bonded)", rssi: -50, updateTimestamp: p.state == .connected)
                    self.attachAndConnectG7Peripheral(p, central: central)
                }

                for rawP in connectedTandem {
                    let p = self.canonicalPeripheral(rawP)
                    let pName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = pName.isEmpty ? "t:slim X2 Pump" : pName
                    self.upsertBLEDevice(id: p.identifier.uuidString, name: displayName, category: "Tandem t:slim X2 (Bonded)", rssi: -48, updateTimestamp: p.state == .connected)
                    self.attachAndConnectTandemPeripheral(p, central: central)
                }

                for rawP in connectedGeneric {
                    let p = self.canonicalPeripheral(rawP)
                    let pName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.isDexcomName(pName) {
                        self.upsertBLEDevice(id: p.identifier.uuidString, name: pName, category: "Dexcom G7 (Bonded)", rssi: -52, updateTimestamp: p.state == .connected)
                        self.attachAndConnectG7Peripheral(p, central: central)
                    } else if Self.isTandemName(pName) {
                        self.upsertBLEDevice(id: p.identifier.uuidString, name: pName, category: "Tandem t:slim X2 (Bonded)", rssi: -48, updateTimestamp: p.state == .connected)
                        self.attachAndConnectTandemPeripheral(p, central: central)
                    } else if self.showAllBLEDevices && !pName.isEmpty {
                        self.upsertBLEDevice(id: p.identifier.uuidString, name: pName, category: "Connected BLE", rssi: -60, updateTimestamp: false)
                    }
                }

                if let savedG7Str, savedG7Str != savedTandemStr, let uuid = UUID(uuidString: savedG7Str) {
                    if let existing = self.g7Peripherals[uuid] {
                        self.attachAndConnectG7Peripheral(existing, central: central)
                    } else {
                        for rawP in retrievedG7ById {
                            let p = self.canonicalPeripheral(rawP)
                            let pName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !Self.isTandemName(pName) && (pName.isEmpty || Self.isDexcomName(pName)) {
                                self.attachAndConnectG7Peripheral(p, central: central)
                            }
                        }
                    }
                }
                if let savedTandemStr, let uuid = UUID(uuidString: savedTandemStr) {
                    if let existing = self.tandemPeripherals[uuid] {
                        self.attachAndConnectTandemPeripheral(existing, central: central)
                    } else {
                        for rawP in retrievedTandemById {
                            let p = self.canonicalPeripheral(rawP)
                            self.attachAndConnectTandemPeripheral(p, central: central)
                        }
                    }
                }
            }
        }
    }

    func upsertBLEDevice(id: String, name: String, category: String, rssi: Int, updateTimestamp: Bool = true) {
        if let idx = bleDevices.firstIndex(where: { $0.id == id }) {
            let prev = bleDevices[idx]
            let now = Date()
            if prev.name == name && prev.category == category && abs(prev.rssi - rssi) <= 4 && (!updateTimestamp || now.timeIntervalSince(prev.lastSeen) < 12.0) {
                return
            }
            bleDevices[idx] = BLEPeripheralDevice(
                id: id,
                name: name,
                category: category,
                rssi: rssi,
                lastSeen: updateTimestamp ? now : prev.lastSeen
            )
        } else {
            bleDevices.insert(
                BLEPeripheralDevice(
                    id: id,
                    name: name,
                    category: category,
                    rssi: rssi,
                    lastSeen: Date()
                ),
                at: 0
            )
        }
    }

    func connectToBLEDevice(id: String) {
        guard let central = centralManager,
              let uuid = UUID(uuidString: id),
              let p = g7Peripherals[uuid] ?? tandemPeripherals[uuid] ?? allDiscoveredPeripherals[uuid] else { return }
        let pName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let devCategory = bleDevices.first(where: { $0.id == id })?.category ?? ""
        discoveredServicePeripherals.remove(uuid)
        if Self.isTandemName(pName) || devCategory.contains("Tandem") {
            attachAndConnectTandemPeripheral(p, central: central)
        } else {
            attachAndConnectG7Peripheral(p, central: central)
        }
    }

    func attachAndConnectG7Peripheral(_ rawPeripheral: CBPeripheral, central: CBCentralManager) {
        let peripheral = canonicalPeripheral(rawPeripheral)
        let rawName = (peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isTandemName(rawName) && tandemPeripherals[peripheral.identifier] == nil else { return }

        g7Peripherals[peripheral.identifier] = peripheral
        let name = rawName.isEmpty ? (g7BLEConnectedName.isEmpty ? "DXCMAK" : g7BLEConnectedName) : rawName
        if Self.isDexcomName(name) {
            if g7BLEConnectedName != name { g7BLEConnectedName = name }
            let idStr = peripheral.identifier.uuidString
            if UserDefaults.standard.string(forKey: Self.savedG7UUIDKey) != idStr {
                UserDefaults.standard.set(idStr, forKey: Self.savedG7UUIDKey)
            }
        }

        let stateLabel = peripheral.state == .connected ? "Dexcom G7 (Connected)" : "Dexcom G7 (Waiting 5m Wake)"
        upsertBLEDevice(
            id: peripheral.identifier.uuidString,
            name: name,
            category: stateLabel,
            rssi: -55,
            updateTimestamp: peripheral.state == .connected
        )

        if peripheral.state == .connected {
            if !discoveredServicePeripherals.contains(peripheral.identifier) {
                discoveredServicePeripherals.insert(peripheral.identifier)
                g7BLEStatus = "Connected to \(name) · Discovering G7 GATT…"
                peripheral.discoverServices(nil)
            }
        } else if peripheral.state == .disconnected {
            discoveredServicePeripherals.remove(peripheral.identifier)
            if lastBLEGlucoseDate == nil {
                let codeInfo = g7PairingCode.isEmpty ? "enter 4-digit code" : "Code \(g7PairingCode) armed"
                g7BLEStatus = "Locked onto \(name) (\(codeInfo)) · Waiting for next 5-min G7 wake pulse…"
            }
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        }
    }

    func attachAndConnectTandemPeripheral(_ rawPeripheral: CBPeripheral, central: CBCentralManager) {
        let peripheral = canonicalPeripheral(rawPeripheral)
        tandemPeripherals[peripheral.identifier] = peripheral
        // Ensure Tandem UUID is never in g7Peripherals
        g7Peripherals.removeValue(forKey: peripheral.identifier)
        let idStr = peripheral.identifier.uuidString
        if UserDefaults.standard.string(forKey: Self.savedG7UUIDKey) == idStr {
            UserDefaults.standard.removeObject(forKey: Self.savedG7UUIDKey)
        }
        if UserDefaults.standard.string(forKey: Self.savedTandemUUIDKey) != idStr {
            UserDefaults.standard.set(idStr, forKey: Self.savedTandemUUIDKey)
        }

        let rawName = (peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? "t:slim X2 Pump" : rawName
        if pumpStatus.pumpSerialNumber != name {
            pumpStatus.pumpSerialNumber = name
        }
        upsertBLEDevice(
            id: peripheral.identifier.uuidString,
            name: name,
            category: peripheral.state == .connected ? "Tandem t:slim X2 (Connected)" : "Tandem t:slim X2 (Connecting)",
            rssi: -48,
            updateTimestamp: peripheral.state == .connected
        )

        if peripheral.state == .connected {
            if !discoveredServicePeripherals.contains(peripheral.identifier) {
                discoveredServicePeripherals.insert(peripheral.identifier)
                tandemBLEStatus = "Connected to \(name) · Discovering Tandem GATT services…"
                peripheral.discoverServices(nil)
            } else if tandemGattReady && !tandemRequestInFlight && !tandemAuthInProgress {
                let lastPoll = lastTandemPollAt[peripheral.identifier] ?? .distantPast
                if Date().timeIntervalSince(lastPoll) >= 20 {
                    if tandemAuthenticator.hasCredentialsOrSecret && !tandemAuthenticator.isAuthenticated {
                        startTandemBLEAuth(on: peripheral)
                    } else if !tandemNeedsPairingCode {
                        requestTandemLiveStatus(on: peripheral)
                    }
                }
            }
        } else if peripheral.state == .disconnected {
            let now = Date()
            let lastAttempt = lastTandemConnectAttemptAt[peripheral.identifier] ?? .distantPast
            let cooldown: TimeInterval = (tandemNeedsPairingCode && !tandemAuthenticator.hasCredentialsOrSecret) ? 18.0 : 4.0
            guard now.timeIntervalSince(lastAttempt) >= cooldown else { return }
            lastTandemConnectAttemptAt[peripheral.identifier] = now
            discoveredServicePeripherals.remove(peripheral.identifier)
            tandemGattReady = false
            if !tandemNeedsPairingCode || tandemAuthenticator.hasCredentialsOrSecret {
                tandemBLEStatus = "Connecting to \(name)…"
            }
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
        if isShowingSimulatedData {
            clearSimulatedData()
        }
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

    // MARK: - 5. Simulated Data (ONLY when demoMode == true) & Live Clear

    func clearSimulatedData() {
        isShowingSimulatedData = false
        UserDefaults.standard.removeObject(forKey: "gluco.pumpStatus")
        UserDefaults.standard.removeObject(forKey: "gluco.pumpEvents")

        let hasFakeEvents = pumpEvents.contains {
            ($0.note ?? "").contains("Lunch meal bolus (Control-IQ)")
            || ($0.note ?? "").contains("Filled cartridge (200 U) & tubing prime")
        }
        if hasFakeEvents {
            pumpEvents = []
            UserDefaults.standard.removeObject(forKey: Self.pumpEventsKey)
        }
        if (pumpStatus.iobUnits == 1.65 && pumpStatus.reservoirUnits == 148.0)
            || (pumpStatus.iobUnits == 1.45 && pumpStatus.reservoirUnits == 142.0) {
            pumpStatus = TandemPumpStatus()
            UserDefaults.standard.removeObject(forKey: Self.pumpStatusKey)
        }
        if readings.count == 288 && lastBLEGlucoseDate == nil && !dexcomConnected && !tandemConnected {
            readings = []
            UserDefaults.standard.removeObject(forKey: Self.readingsKey)
        }
    }

    func loadSimulatedData() {
        guard demoMode else {
            clearSimulatedData()
            return
        }
        isShowingSimulatedData = true
        let now = Date()
        var simReadings: [GlucoseReading] = []
        for i in stride(from: 287, through: 0, by: -1) {
            let t = now.addingTimeInterval(Double(-i * 300))
            let hoursAgo = Double(i) * 5.0 / 60.0
            let wave1 = 28.0 * sin(hoursAgo * 0.65)
            let wave2 = 16.0 * cos(hoursAgo * 0.35)
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
        pumpStatus = TandemPumpStatus(
            iobUnits: 1.65,
            cobGrams: 18,
            activeBasalRate: 0.95,
            scheduledBasalRate: 0.85,
            batteryPercent: 84,
            reservoirUnits: 148.0,
            controlIQMode: "Demo Control-IQ",
            lastBolusUnits: 3.20,
            lastBolusDate: now.addingTimeInterval(-48 * 60),
            lastSyncDate: now,
            pumpSerialNumber: "Demo t:slim X2"
        )
        pumpEvents = [
            PumpEvent(type: .basalModulation, timestamp: now.addingTimeInterval(-15 * 60), insulinUnits: nil, carbsGrams: nil, basalRate: 1.15, note: "Control-IQ increased basal to 1.15 U/hr"),
            PumpEvent(type: .mealBolus, timestamp: now.addingTimeInterval(-65 * 60), insulinUnits: 3.40, carbsGrams: 42, basalRate: nil, note: "Lunch meal bolus (Control-IQ)"),
            PumpEvent(type: .autoCorrection, timestamp: now.addingTimeInterval(-140 * 60), insulinUnits: 0.85, carbsGrams: nil, basalRate: nil, note: "Control-IQ automatic correction bolus"),
            PumpEvent(type: .basalModulation, timestamp: now.addingTimeInterval(-210 * 60), insulinUnits: nil, carbsGrams: nil, basalRate: 0.85, note: "Control-IQ scheduled profile basal"),
            PumpEvent(type: .mealBolus, timestamp: now.addingTimeInterval(-360 * 60), insulinUnits: 4.10, carbsGrams: 50, basalRate: nil, note: "Breakfast bolus"),
            PumpEvent(type: .siteChange, timestamp: now.addingTimeInterval(-19 * 3600), insulinUnits: nil, carbsGrams: nil, basalRate: nil, note: "Filled cartridge (200 U) & tubing prime")
        ]
    }

    private func checkGlucoseAlerts() {
        guard alertsEnabled, !isAlertSnoozed, let latest = latestReading else { return }
        let now = Date()
        // Ignore stale readings older than 20 minutes
        guard now.timeIntervalSince(latest.timestamp) <= 1200 else { return }

        let d = UserDefaults.standard
        let content = UNMutableNotificationContent()

        if latest.mgdL <= urgentLowMgdL {
            let cooldown: TimeInterval = 15 * 60
            guard now.timeIntervalSince(lastUrgentLowAlertAt) >= cooldown else { return }
            lastAlertBand = "urgentLow"
            lastUrgentLowAlertAt = now
            d.set(lastAlertBand, forKey: Self.lastAlertBandKey)
            d.set(now.timeIntervalSince1970, forKey: Self.lastUrgentLowAlertAtKey)

            content.title = "Urgent Low Glucose (\(formatGlucose(latest.mgdL)) \(unit.rawValue))"
            content.body = "Dexcom G7 is \(latest.trend.label.lowercased()) (\(latest.trend.arrow)). Tandem IOB: \(String(format: "%.2f U", pumpStatus.iobUnits))."
            content.sound = .defaultCritical
        } else if latest.mgdL < lowMgdL {
            let cooldown: TimeInterval = 30 * 60
            guard now.timeIntervalSince(lastLowAlertAt) >= cooldown else { return }
            lastAlertBand = "low"
            lastLowAlertAt = now
            d.set(lastAlertBand, forKey: Self.lastAlertBandKey)
            d.set(now.timeIntervalSince1970, forKey: Self.lastLowAlertAtKey)

            content.title = "Low Glucose (\(formatGlucose(latest.mgdL)) \(unit.rawValue))"
            content.body = "Dexcom G7 reading is below target (\(latest.trend.arrow)). Active IOB: \(String(format: "%.2f U", pumpStatus.iobUnits))."
            content.sound = .default
        } else if latest.mgdL > highMgdL {
            guard highAlertsEnabled else { return }
            let elapsed = now.timeIntervalSince(lastHighAlertAt)
            if lastAlertBand == "high" {
                // Already alerted for this high excursion — only repeat if repeat interval > 0 and elapsed
                guard highAlertRepeatMinutes > 0, elapsed >= Double(highAlertRepeatMinutes * 60) else { return }
            } else {
                // Newly crossed into high — still enforce at least a 30-minute minimum gap to avoid boundary bounce spam
                guard elapsed >= 30 * 60 else {
                    lastAlertBand = "high"
                    d.set(lastAlertBand, forKey: Self.lastAlertBandKey)
                    return
                }
            }
            lastAlertBand = "high"
            lastHighAlertAt = now
            d.set(lastAlertBand, forKey: Self.lastAlertBandKey)
            d.set(now.timeIntervalSince1970, forKey: Self.lastHighAlertAtKey)

            content.title = "High Glucose (\(formatGlucose(latest.mgdL)) \(unit.rawValue))"
            content.body = "Dexcom G7 reading is above target (\(latest.trend.arrow)). Active IOB: \(String(format: "%.2f U", pumpStatus.iobUnits))."
            content.sound = .default
        } else {
            if lastAlertBand != "normal" {
                lastAlertBand = "normal"
                d.set(lastAlertBand, forKey: Self.lastAlertBandKey)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["gluco.alert"])
            }
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
                    let targetUUIDs: [CBUUID]? = self.showAllBLEDevices ? nil : [
                        Self.g7AdvServiceUUID, Self.g7CGMServiceUUID, Self.g7AltServiceUUID,
                        Self.tandemServiceUUID1, Self.tandemFullServiceUUID, Self.tandemTDUServiceUUID, Self.tandemServiceUUID2
                    ]
                    central.scanForPeripherals(
                        withServices: targetUUIDs,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                    if !self.bleScanning { self.bleScanning = true }
                    if self.lastBLEGlucoseDate == nil {
                        self.g7BLEStatus = "Scanning for Dexcom G7 (\(self.g7BLEConnectedName) · Code \(self.g7PairingCode)) 5-min wake…"
                    }
                }
            } else {
                self.g7BLEStatus = "Bluetooth is off or unauthorized."
                self.tandemBLEStatus = "Bluetooth is off or unauthorized."
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
            || serviceUUIDs.contains(Self.tandemFullServiceUUID)
            || serviceUUIDs.contains(Self.tandemTDUServiceUUID)
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

        let isTandem = hasTandemService || Self.isTandemName(trimmed)
        let isDexcom = !isTandem && (hasG7Service || isDexcomMfg || Self.isDexcomName(trimmed))

        guard isDexcom || isTandem || Self.showAllBLENonisolated else { return }
        let rssiVal = RSSI.intValue
        let uuidStr = peripheral.identifier.uuidString
        let shortId = String(uuidStr.prefix(6))
        let svcSummary = serviceUUIDs.map { $0.uuidString.prefix(4) }.joined(separator: ",")

        Task { @MainActor in
            guard isDexcom || isTandem || self.showAllBLEDevices else { return }
            let p = self.canonicalPeripheral(peripheral)

            let displayName: String
            if !trimmed.isEmpty {
                displayName = trimmed
            } else if isDexcom {
                displayName = self.g7BLEConnectedName.isEmpty ? "DXCMAK" : self.g7BLEConnectedName
            } else if isTandem {
                displayName = "t:slim X2 (\(shortId))"
            } else {
                let extra = !mfgHex.isEmpty ? mfgHex : (!svcSummary.isEmpty ? String(svcSummary) : shortId)
                displayName = "BLE \(extra)"
            }

            let category = isDexcom ? "Dexcom G7 (Live Pulse)" : (isTandem ? "Tandem t:slim X2" : "Nearby BLE")
            self.upsertBLEDevice(id: uuidStr, name: displayName, category: category, rssi: rssiVal, updateTimestamp: true)

            if self.g7DirectBLEEnabled {
                if isDexcom {
                    self.g7BLEStatus = "Caught \(displayName) wake pulse (\(rssiVal) dBm) · Connecting…"
                    self.attachAndConnectG7Peripheral(p, central: central)
                } else if isTandem {
                    self.attachAndConnectTandemPeripheral(p, central: central)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let rawName = (peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isTandem = Self.isTandemName(rawName)
        peripheral.delegate = self
        Task { @MainActor in
            let p = self.canonicalPeripheral(peripheral)
            self.discoveredServicePeripherals.insert(p.identifier)
            if isTandem || self.tandemPeripherals[p.identifier] != nil {
                let pumpName = rawName.isEmpty ? "t:slim X2 Pump" : rawName
                if self.pumpStatus.pumpSerialNumber != pumpName {
                    self.pumpStatus.pumpSerialNumber = pumpName
                }
                self.tandemGattReady = false
                self.tandemRequestInFlight = false
                self.tandemRequestGeneration &+= 1
                self.tandemAuthInProgress = false
                self.tandemAuthenticator.pairingCode = self.tandemPairingCode
                self.tandemAuthenticator.resetSession(clearPersistedSecret: false)
                self.tandemTxId = 0
                self.tandemTxMismatchRetries = 0
                self.tandemRepliesReceivedCount = 0
                self.tandemPacketBuffers.removeAll()
                self.tandemAuthPacketBuffers.removeAll()
                self.pendingTandemNotifyUUIDs.removeAll()
                self.upsertBLEDevice(id: p.identifier.uuidString, name: pumpName, category: "Tandem t:slim X2 (Connected)", rssi: -48, updateTimestamp: true)
                self.tandemBLEStatus = "Connected to \(pumpName) · Discovering GATT services…"
                p.discoverServices(nil)
            } else {
                let name = rawName.isEmpty ? (self.g7BLEConnectedName.isEmpty ? "DXCMAK" : self.g7BLEConnectedName) : rawName
                self.g7BLEConnectedName = name
                if Self.isDexcomName(name) {
                    UserDefaults.standard.set(name, forKey: Self.g7SensorNameKey)
                    self.g7Authenticator.transmitterID = name
                }
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
                self.upsertBLEDevice(id: p.identifier.uuidString, name: name, category: "Dexcom G7 (Connected)", rssi: -52, updateTimestamp: true)
                self.g7BLEStatus = "Connected to \(name) · Discovering G7 GATT…"
                p.discoverServices(nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let rawName = (peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let p = self.canonicalPeripheral(peripheral)
            self.discoveredServicePeripherals.remove(p.identifier)
            let isTandem = Self.isTandemName(rawName) || self.tandemPeripherals[p.identifier] != nil
            if isTandem {
                self.tandemGattReady = false
                self.tandemRequestInFlight = false
                self.tandemRequestGeneration &+= 1
                self.tandemAuthInProgress = false
                self.lastTandemConnectAttemptAt[p.identifier] = Date()
                let pumpName = self.pumpStatus.pumpSerialNumber.isEmpty ? (rawName.isEmpty ? "t:slim X2" : rawName) : self.pumpStatus.pumpSerialNumber
                if !self.tandemAuthenticator.hasCredentialsOrSecret && self.tandemRepliesReceivedCount == 0 {
                    self.tandemNeedsPairingCode = true
                    self.tandemBLEStatus = "iOS paired with \(pumpName) · Enter 6-digit/16-char Pump Pairing Code (Options → Device Settings → Bluetooth → Pair Device) below!"
                    return
                } else {
                    self.tandemBLEStatus = "\(pumpName) disconnected · Reconnecting in 3s…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        guard let self, self.g7DirectBLEEnabled, p.state == .disconnected else { return }
                        central.connect(p, options: [
                            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                            CBConnectPeripheralOptionNotifyOnNotificationKey: true
                        ])
                    }
                    return
                }
            } else {
                self.g7WriteGeneration &+= 1
            }
            if self.g7DirectBLEEnabled {
                let name = rawName.isEmpty ? self.g7BLEConnectedName : rawName
                if self.lastBLEGlucoseDate == nil {
                    if self.g7Authenticator.hasConfirmedSharedKey {
                        self.g7BLEStatus = "Paired with \(name) · Waiting for next 5-min G7 wake tick…"
                    } else {
                        self.g7BLEStatus = "Waiting for next 5-min G7 wake from \(name) (Code \(self.g7PairingCode))…"
                    }
                }
                central.connect(p, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let errDesc = error?.localizedDescription
        let svcCount = peripheral.services?.count ?? 0
        Task { @MainActor in
            let p = self.canonicalPeripheral(peripheral)
            let isTandem = self.tandemPeripherals[p.identifier] != nil || Self.isTandemName(p.name ?? "")
            if let errDesc {
                if isTandem {
                    self.tandemBLEStatus = "Tandem GATT service error: \(errDesc)"
                } else {
                    self.g7BLEStatus = "G7 GATT service error: \(errDesc)"
                }
                return
            }
            guard let services = p.services, !services.isEmpty else {
                if isTandem {
                    self.tandemBLEStatus = "Connected to \(p.name ?? "t:slim X2") · 0 GATT services exposed (check iOS Bluetooth pairing)."
                }
                return
            }
            if isTandem {
                self.tandemBLEStatus = "Connected to \(p.name ?? "t:slim X2") · Found \(svcCount) services · Reading characteristics…"
            } else {
                self.g7BLEStatus = "Connected to \(self.g7BLEConnectedName) · Found \(svcCount) services · Reading characteristics…"
            }
            for service in services {
                p.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        Task { @MainActor in
            let p = self.canonicalPeripheral(peripheral)
            var foundG7 = false
            var foundTandem = false
            for ch in chars {
                switch ch.uuid {
                case Self.g7AuthStreamCharUUID:
                    self.g7AuthStreamChar = ch
                    foundG7 = true
                case Self.g7AuthCharUUID:
                    self.g7AuthChar = ch
                    foundG7 = true
                case Self.g7ControlCharUUID:
                    self.g7ControlChar = ch
                    foundG7 = true
                case Self.g7BackfillCharUUID:
                    self.g7BackfillChar = ch
                    foundG7 = true

                case Self.tandemCurrentStatusCharUUID:
                    self.tandemCurrentStatusChar = ch
                    self.tandemPeripherals[p.identifier] = p
                    foundTandem = true
                    if !ch.isNotifying {
                        self.pendingTandemNotifyUUIDs.insert(ch.uuid)
                        p.setNotifyValue(true, for: ch)
                    }
                case Self.tandemQualifyingEventsCharUUID:
                    self.tandemQualifyingEventsChar = ch
                    foundTandem = true
                    if !ch.isNotifying {
                        self.pendingTandemNotifyUUIDs.insert(ch.uuid)
                        p.setNotifyValue(true, for: ch)
                    }
                case Self.tandemHistoryLogCharUUID:
                    self.tandemHistoryLogChar = ch
                    foundTandem = true
                    if !ch.isNotifying {
                        self.pendingTandemNotifyUUIDs.insert(ch.uuid)
                        p.setNotifyValue(true, for: ch)
                    }
                case Self.tandemAuthCharUUID:
                    self.tandemAuthChar = ch
                    foundTandem = true
                    if !ch.isNotifying {
                        self.pendingTandemNotifyUUIDs.insert(ch.uuid)
                        p.setNotifyValue(true, for: ch)
                    }
                case Self.tandemControlCharUUID:
                    self.tandemControlChar = ch
                    foundTandem = true
                case Self.tandemControlStreamCharUUID:
                    self.tandemControlStreamChar = ch
                    foundTandem = true

                case Self.disManufacturerCharUUID, Self.disModelNumberCharUUID, Self.disSerialNumberCharUUID, Self.disSoftwareRevCharUUID:
                    p.readValue(for: ch)

                case Self.batteryLevelCharUUID:
                    p.readValue(for: ch)
                    if ch.properties.contains(.notify) && !ch.isNotifying {
                        p.setNotifyValue(true, for: ch)
                    }
                default:
                    break
                }
            }

            if foundTandem {
                UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedTandemUUIDKey)
                if self.pendingTandemNotifyUUIDs.isEmpty && (self.tandemCurrentStatusChar?.isNotifying == true) {
                    self.onTandemNotificationsReady(peripheral: p)
                } else {
                    self.tandemBLEStatus = "Connected to \(p.name ?? "t:slim X2") · Enabling notifications (\(self.pendingTandemNotifyUUIDs.count) channels)…"
                    // Fallback timer in case an optional characteristic doesn't fire didUpdateNotificationStateFor
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, !self.tandemGattReady, self.tandemCurrentStatusChar != nil else { return }
                        self.onTandemNotificationsReady(peripheral: p)
                    }
                }
            }

            if foundG7 {
                UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedG7UUIDKey)
                if let streamCh = self.g7AuthStreamChar, !streamCh.isNotifying {
                    p.setNotifyValue(true, for: streamCh)
                }
                if let authCh = self.g7AuthChar, !authCh.isNotifying {
                    p.setNotifyValue(true, for: authCh)
                }
                if (self.g7AuthStreamChar?.isNotifying ?? true) && (self.g7AuthChar?.isNotifying ?? false) {
                    self.startG7AuthHandshakeIfNeeded(peripheral: p)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        let errDesc = error?.localizedDescription
        Task { @MainActor in
            let p = self.canonicalPeripheral(peripheral)
            if self.pendingTandemNotifyUUIDs.contains(uuid) || uuid == Self.tandemCurrentStatusCharUUID || uuid == Self.tandemAuthCharUUID {
                self.pendingTandemNotifyUUIDs.remove(uuid)
                if let errDesc {
                    self.tandemBLEStatus = "Tandem notify warning (\(uuid.uuidString.prefix(8))): \(errDesc)"
                }
                if self.pendingTandemNotifyUUIDs.isEmpty && !self.tandemGattReady && (self.tandemCurrentStatusChar?.isNotifying == true) {
                    self.onTandemNotificationsReady(peripheral: p)
                }
                return
            }
            if uuid == Self.g7AuthStreamCharUUID && isNotifying {
                if let authCh = self.g7AuthChar, !authCh.isNotifying {
                    p.setNotifyValue(true, for: authCh)
                } else if self.g7AuthChar?.isNotifying == true {
                    self.startG7AuthHandshakeIfNeeded(peripheral: p)
                }
                return
            }
            if uuid == Self.g7AuthCharUUID && isNotifying {
                self.startG7AuthHandshakeIfNeeded(peripheral: p)
                return
            }
            if uuid == Self.g7ControlCharUUID && isNotifying {
                let wType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                p.writeValue(Data([0x4E]), for: characteristic, type: wType)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        let uuid = characteristic.uuid
        let errDesc = error.localizedDescription
        Task { @MainActor in
            if uuid == Self.tandemCurrentStatusCharUUID || uuid == Self.tandemAuthCharUUID {
                self.tandemBLEStatus = "t:slim X2 BLE write error (\(uuid.uuidString.prefix(8))): \(errDesc)"
            }
        }
    }

    // MARK: - Direct Tandem t:slim X2 BLE CURRENT_STATUS & AUTHORIZATION Protocol (jwoglom/pumpX2)

    nonisolated private static let tandemCRCTable: [UInt16] = [
        0, 4129, 8258, 12387, 16516, 20645, 24774, 28903, 33032, 37161, 41290, 45419, 49548, 53677, 57806, 61935,
        4657, 528, 12915, 8786, 21173, 17044, 29431, 25302, 37689, 33560, 45947, 41818, 54205, 50076, 62463, 58334,
        9314, 13379, 1056, 5121, 25830, 29895, 17572, 21637, 42346, 46411, 34088, 38153, 58862, 62927, 50604, 54669,
        13907, 9842, 5649, 1584, 30423, 26358, 22165, 18100, 46939, 42874, 38681, 34616, 63455, 59390, 55197, 51132,
        18628, 22757, 26758, 30887, 2112, 6241, 10242, 14371, 51660, 55789, 59790, 63919, 35144, 39273, 43274, 47403,
        23285, 19156, 31415, 27286, 6769, 2640, 14899, 10770, 56317, 52188, 64447, 60318, 39801, 35672, 47931, 43802,
        27814, 31879, 19684, 23749, 11298, 15363, 3168, 7233, 60846, 64911, 52716, 56781, 44330, 48395, 36200, 40265,
        32407, 28342, 24277, 20212, 15891, 11826, 7761, 3696, 65439, 61374, 57309, 53244, 48923, 44858, 40793, 36728,
        37256, 33193, 45514, 41451, 53516, 49453, 61774, 57711, 4224, 161, 12482, 8419, 20484, 16421, 28742, 24679,
        33721, 37784, 41979, 46042, 49981, 54044, 58239, 62302, 689, 4752, 8947, 13010, 16949, 21012, 25207, 29270,
        46570, 42443, 38312, 34185, 62830, 58703, 54572, 50445, 13538, 9411, 5280, 1153, 29798, 25671, 21540, 17413,
        42971, 47098, 34713, 38840, 59231, 63358, 50973, 55100, 9939, 14066, 1681, 5808, 26199, 30326, 17941, 22068,
        55628, 51565, 63758, 59695, 39368, 35305, 47498, 43435, 22596, 18533, 30726, 26663, 6336, 2273, 14466, 10403,
        52093, 56156, 60223, 64286, 35833, 39896, 43963, 48026, 19061, 23124, 27191, 31254, 2801, 6864, 10931, 14994,
        64814, 60687, 56684, 52557, 48554, 44427, 40424, 36297, 31782, 27655, 23652, 19525, 15522, 11395, 7392, 3265,
        61215, 65342, 53085, 57212, 44955, 49082, 36825, 40952, 28183, 32310, 20053, 24180, 11923, 16050, 3793, 7920
    ]

    nonisolated private static func makeTandemPackets(opCode: UInt8, txId: UInt8, cargo: [UInt8] = [], maxChunkSize: Int = 18) -> [Data] {
        var msg: [UInt8] = [opCode, txId, UInt8(cargo.count & 0xFF)]
        msg.append(contentsOf: cargo)
        var crc: UInt16 = 0xFFFF
        for b in msg {
            let idx = Int((b ^ UInt8((crc >> 8) & 0xFF)))
            crc = (crc << 8) ^ tandemCRCTable[idx]
        }
        msg.append(UInt8(crc & 0xFF))
        msg.append(UInt8((crc >> 8) & 0xFF))

        var chunks: [[UInt8]] = []
        var idx = 0
        while idx < msg.count {
            let end = min(idx + maxChunkSize, msg.count)
            chunks.append(Array(msg[idx..<end]))
            idx = end
        }
        let total = chunks.count
        return chunks.enumerated().map { (i, chunk) in
            let remaining = UInt8((total - 1 - i) & 0xFF)
            var pkt: [UInt8] = [remaining, txId]
            pkt.append(contentsOf: chunk)
            return Data(pkt)
        }
    }

    @MainActor
    private func onTandemNotificationsReady(peripheral: CBPeripheral) {
        guard !tandemGattReady else { return }
        tandemGattReady = true
        tandemAuthenticator.pairingCode = tandemPairingCode
        let pumpName = pumpStatus.pumpSerialNumber.isEmpty ? (peripheral.name ?? "t:slim X2") : pumpStatus.pumpSerialNumber

        // CRITICAL: If we have a saved JPAKE secret or a 6-digit/16-char pairing code, we MUST
        // authenticate on AUTHORIZATION (7B83FFF9) FIRST within the pump's 5-second window!
        if tandemAuthenticator.hasCredentialsOrSecret && !tandemAuthenticator.isAuthenticated {
            tandemNeedsPairingCode = false
            tandemBLEStatus = "Connected to \(pumpName) · Authenticating Tandem BLE session…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, peripheral.state == .connected else { return }
                self.startTandemBLEAuth(on: peripheral)
            }
            return
        }

        if tandemAuthenticator.isAuthenticated {
            tandemNeedsPairingCode = false
            tandemBLEStatus = "Connected to \(pumpName) · Requesting live CGM & IOB…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, peripheral.state == .connected else { return }
                self.requestTandemLiveStatus(on: peripheral)
            }
            return
        }

        // Otherwise (no pairing code entered yet in GlucoPulse), send ONE single probe (opCode 34)
        // in case the official t:connect app is sharing an already-authenticated BLE link.
        tandemBLEStatus = "Connected to \(pumpName) · Checking shared BLE session…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, peripheral.state == .connected else { return }
            self.tandemRequestQueue = [34]
            self.sendNextTandemStatusRequest(on: peripheral)
        }
    }

    @MainActor
    private func requestTandemLiveStatus(on peripheral: CBPeripheral) {
        guard tandemCurrentStatusChar != nil, peripheral.state == .connected else { return }
        lastTandemPollAt[peripheral.identifier] = Date()
        // Sequential queue:
        // 34 = CurrentEGVGuiDataRequest (G7 CGM glucose + trend on pump)
        // 108 = ControlIQIOBRequest (active IOB)
        // 40 = CurrentBasalStatusRequest (active & scheduled basal rate)
        // 36 = InsulinStatusRequest (cartridge units remaining)
        // 52 = CurrentBatteryV1Request (pump battery %)
        // 164 = LastBolusStatusV2Request & 48 = LastBolusStatusRequest
        // 56 = HomeScreenMirrorRequest (trend & Control-IQ state icons)
        // 60 = CGMStatusRequest
        // 32 = ApiVersionRequest
        tandemRequestQueue = [34, 108, 40, 36, 52, 164, 48, 56, 60, 32]
        if !tandemRequestInFlight {
            sendNextTandemStatusRequest(on: peripheral)
        }
    }

    @MainActor
    private func sendNextTandemStatusRequest(on peripheral: CBPeripheral) {
        guard peripheral.state == .connected,
              let ch = tandemCurrentStatusChar,
              !tandemAuthInProgress else {
            tandemRequestInFlight = false
            return
        }
        guard !tandemRequestQueue.isEmpty else {
            tandemRequestInFlight = false
            return
        }
        tandemRequestInFlight = true
        tandemRequestGeneration &+= 1
        let gen = tandemRequestGeneration
        let op = tandemRequestQueue.removeFirst()
        let tx = tandemTxId
        tandemTxId = tandemTxId &+ 1
        let pkts = Self.makeTandemPackets(opCode: op, txId: tx, cargo: [])
        let wType: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        for pkt in pkts {
            peripheral.writeValue(pkt, for: ch, type: wType)
        }

        let timeoutSec: TimeInterval = (tandemRepliesReceivedCount == 0 && !tandemAuthenticator.isAuthenticated) ? 1.4 : 0.45
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
            guard let self,
                  self.tandemRequestGeneration == gen,
                  self.tandemRequestInFlight,
                  !self.tandemAuthInProgress else { return }
            if !self.tandemRequestQueue.isEmpty {
                self.sendNextTandemStatusRequest(on: peripheral)
            } else {
                self.tandemRequestInFlight = false
                if self.tandemRepliesReceivedCount == 0 {
                    if self.tandemAuthenticator.hasCredentialsOrSecret && !self.tandemAuthenticator.isAuthenticated {
                        self.startTandemBLEAuth(on: peripheral)
                    } else if !self.tandemAuthenticator.hasCredentialsOrSecret {
                        let pumpName = self.pumpStatus.pumpSerialNumber.isEmpty ? (peripheral.name ?? "t:slim X2") : self.pumpStatus.pumpSerialNumber
                        self.tandemNeedsPairingCode = true
                        self.tandemBLEStatus = "iOS paired with \(pumpName) · Enter 6-digit or 16-char Pump Pairing Code (Options → Device Settings → Bluetooth → Pair Device) below!"
                    }
                }
            }
        }
    }

    @MainActor
    func startTandemBLEAuth(on peripheral: CBPeripheral) {
        guard peripheral.state == .connected,
              let authCh = tandemAuthChar else {
            tandemBLEStatus = "Connected to \(pumpStatus.pumpSerialNumber) · Enter Pump Pairing Code below."
            return
        }
        tandemAuthenticator.pairingCode = tandemPairingCode
        guard let initMsg = tandemAuthenticator.makeInitialAuthMessage() else {
            tandemNeedsPairingCode = true
            tandemBLEStatus = "Enter Tandem Pairing Code (Pump: Options → Device Settings → Bluetooth Settings → Pair Device)."
            return
        }
        tandemNeedsPairingCode = false
        tandemAuthInProgress = true
        tandemRequestInFlight = false
        tandemRequestGeneration &+= 1
        let tx = tandemTxId
        tandemTxId = tandemTxId &+ 1
        let pkts = Self.makeTandemPackets(opCode: initMsg.opCode, txId: tx, cargo: initMsg.cargo)
        let wType: CBCharacteristicWriteType = authCh.properties.contains(.write) ? .withResponse : .withoutResponse
        tandemBLEStatus = initMsg.description
        for (idx, pkt) in pkts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025 * Double(idx)) {
                guard peripheral.state == .connected else { return }
                peripheral.writeValue(pkt, for: authCh, type: wType)
            }
        }
    }

    @MainActor
    private func handleTandemAuthNotification(_ bytes: [UInt8], from peripheral: CBPeripheral) {
        guard bytes.count >= 3 else { return }
        let packetsRemaining = bytes[0] & 0x0F
        let txId = bytes[1]
        if tandemTxId <= txId {
            tandemTxId = txId &+ 1
        }
        let chunk = Array(bytes.dropFirst(2))

        var accumulated = tandemAuthPacketBuffers[txId] ?? []
        accumulated.append(contentsOf: chunk)
        if packetsRemaining > 0 {
            tandemAuthPacketBuffers[txId] = accumulated
            return
        }
        tandemAuthPacketBuffers.removeValue(forKey: txId)

        guard accumulated.count >= 5 else { return }
        let opCode = accumulated[0]
        let cargoLen = Int(accumulated[2])
        let availableCargo = max(0, accumulated.count - 5)
        let actualLen = min(cargoLen, availableCargo)
        let cargo = Array(accumulated[3..<(3 + actualLen)])

        if opCode == 77 { // ErrorResponse on AUTHORIZATION
            tandemAuthInProgress = false
            let errCode = cargo.count >= 2 ? cargo[1] : 0
            // If fast session key confirm (op 38) failed because pump was re-paired, clear secret and retry full bootstrap
            if tandemAuthenticator.triedFastConfirmInSession {
                tandemAuthenticator.resetSession(clearPersistedSecret: true)
                if tandemAuthenticator.isSixDigitMode {
                    startTandemBLEAuth(on: peripheral)
                    return
                }
            }
            tandemNeedsPairingCode = true
            tandemBLEStatus = "t:slim X2 Auth Response (err=\(errCode)) · Enter 6-digit or 16-char Pump Pairing Code below."
            return
        }

        if opCode == 17 && tandemAuthenticator.cleanPairingCode.count != 16 {
            tandemAuthInProgress = false
            tandemNeedsPairingCode = true
            tandemBLEStatus = "t:slim X2 ready · Enter 16-char Pump Pairing Code (Options → Device Settings → Bluetooth Settings → Pair Device)!"
            return
        }

        if let nextStep = tandemAuthenticator.handleAuthorizationResponse(opCode: opCode, cargo: cargo) {
            tandemBLEStatus = nextStep.statusText
            if nextStep.nextOpCode != 0, let authCh = tandemAuthChar {
                let tx = tandemTxId
                tandemTxId = tandemTxId &+ 1
                let pkts = Self.makeTandemPackets(opCode: nextStep.nextOpCode, txId: tx, cargo: nextStep.nextCargo)
                let wType: CBCharacteristicWriteType = authCh.properties.contains(.write) ? .withResponse : .withoutResponse
                for (idx, pkt) in pkts.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025 * Double(idx)) {
                        guard peripheral.state == .connected else { return }
                        peripheral.writeValue(pkt, for: authCh, type: wType)
                    }
                }
            } else {
                tandemAuthInProgress = false
                if tandemAuthenticator.isAuthenticated {
                    tandemNeedsPairingCode = false
                    requestTandemLiveStatus(on: peripheral)
                } else {
                    tandemNeedsPairingCode = true
                }
            }
        }
    }

    @MainActor
    private func updateTandemLiveSummaryBanner() {
        var parts: [String] = ["Live t:slim X2 BLE"]
        if let latest = latestReading, let bleDate = lastBLEGlucoseDate, Date().timeIntervalSince(bleDate) < 1800 {
            parts.append("CGM \(formatGlucose(latest.mgdL)) \(unit.rawValue) \(latest.trend.arrow)")
        }
        parts.append(String(format: "IOB %.2f U", pumpStatus.iobUnits))
        if pumpStatus.activeBasalRate > 0 || pumpStatus.scheduledBasalRate > 0 {
            parts.append(String(format: "Basal %.2f U/h", pumpStatus.activeBasalRate))
        }
        if pumpStatus.reservoirUnits > 0 {
            parts.append("\(Int(pumpStatus.reservoirUnits)) U")
        }
        if pumpStatus.batteryPercent > 0 {
            parts.append("\(pumpStatus.batteryPercent)%")
        }
        tandemBLEStatus = parts.joined(separator: " · ")
    }

    @MainActor
    private func handleTandemCurrentStatusNotification(_ bytes: [UInt8], from peripheral: CBPeripheral) {
        guard bytes.count >= 3 else { return }
        let packetsRemaining = bytes[0] & 0x0F
        let txId = bytes[1]
        // Always sync our next txId to 1 + the pump's latest txId
        if tandemTxId <= txId {
            tandemTxId = txId &+ 1
        }
        let chunk = Array(bytes.dropFirst(2))

        var accumulated = tandemPacketBuffers[txId] ?? []
        accumulated.append(contentsOf: chunk)
        if packetsRemaining > 0 {
            tandemPacketBuffers[txId] = accumulated
            return
        }
        tandemPacketBuffers.removeValue(forKey: txId)

        guard accumulated.count >= 5 else { return }
        let opCode = accumulated[0]
        let cargoLen = Int(accumulated[2])
        guard accumulated.count >= 3 + cargoLen else { return }
        let cargo = Array(accumulated[3..<(3 + cargoLen)])

        // Handle ErrorResponse (opCode == 77)
        if opCode == 77 {
            let reqOp = cargo.count >= 1 ? cargo[0] : 0
            let errCode = cargo.count >= 2 ? cargo[1] : 0
            if errCode == 3 { // TRANSACTION_ID_MISMATCH
                tandemTxMismatchRetries += 1
                if tandemTxMismatchRetries <= 40 {
                    if reqOp != 0 && !tandemRequestQueue.contains(reqOp) {
                        tandemRequestQueue.insert(reqOp, at: 0)
                    }
                    tandemBLEStatus = "Syncing t:slim X2 transaction ID (txId=\(tandemTxId))…"
                    sendNextTandemStatusRequest(on: peripheral)
                }
                return
            } else if errCode == 9 { // INVALID_AUTHENTICATION_ERROR
                tandemRequestQueue.removeAll()
                tandemRequestInFlight = false
                if tandemAuthenticator.hasCredentialsOrSecret {
                    startTandemBLEAuth(on: peripheral)
                } else {
                    tandemNeedsPairingCode = true
                    tandemBLEStatus = "t:slim X2 requires BLE Pairing Code (Options → Device Settings → Bluetooth → Pair Device)."
                }
                return
            } else {
                tandemBLEStatus = "t:slim X2 status response (op=\(reqOp), code=\(errCode)) · Continuing…"
                sendNextTandemStatusRequest(on: peripheral)
                return
            }
        }

        let wasFirstReply = (tandemRepliesReceivedCount == 0)
        tandemRepliesReceivedCount += 1
        tandemTxMismatchRetries = 0
        tandemNeedsPairingCode = false
        if wasFirstReply && tandemRequestQueue.isEmpty {
            // Shared connection probe succeeded! Queue the remaining telemetry requests
            tandemRequestQueue = [108, 40, 36, 52, 164, 48, 56, 60, 32]
        }

        if isShowingSimulatedData || demoMode {
            clearSimulatedData()
            if demoMode { demoMode = false }
        }
        tandemConnected = true
        pumpStatus.lastSyncDate = Date()

        let Jan1_2008_Epoch: TimeInterval = 1199145600

        switch opCode {
        case 33: // ApiVersionResponse (4B: major[2], minor[2])
            if cargo.count >= 4 {
                let major = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
                let minor = UInt16(cargo[2]) | (UInt16(cargo[3]) << 8)
                tandemBLEStatus = "Connected to \(pumpStatus.pumpSerialNumber) (API v\(major).\(minor)) · Reading CGM & IOB…"
            }

        case 35: // CurrentEGVGuiDataResponse (8B: timestamp[4], cgmReading[2], status[1], trendRate[1])
            if cargo.count >= 8 {
                let tsSec = UInt32(cargo[0]) | (UInt32(cargo[1]) << 8) | (UInt32(cargo[2]) << 16) | (UInt32(cargo[3]) << 24)
                let cgmMgdL = Int(UInt16(cargo[4]) | (UInt16(cargo[5]) << 8))
                let rawTrend = Int8(bitPattern: cargo[7])
                if (20...500).contains(cgmMgdL) {
                    let trend = Self.trendFromG7Rate(rawTrend)
                    let isNewPumpCGMReading = (tsSec != lastTandemCGMTimestampRaw) || (cgmMgdL != lastTandemCGMMgdL) || readings.isEmpty
                    lastTandemCGMTimestampRaw = tsSec
                    lastTandemCGMMgdL = cgmMgdL
                    dexcomConnected = true

                    if isNewPumpCGMReading {
                        let pumpDate = Date(timeIntervalSince1970: Jan1_2008_Epoch + TimeInterval(tsSec))
                        let readingDate = abs(Date().timeIntervalSince(pumpDate)) <= 1800 ? min(Date(), pumpDate) : Date()
                        let reading = GlucoseReading(mgdL: cgmMgdL, timestamp: readingDate, trend: trend)
                        lastBLEGlucoseDate = readingDate
                        mergeReadings([reading])
                        checkGlucoseAlerts()
                        Task { await self.uploadBLEReadingsToNightscout([reading]) }
                    } else if lastBLEGlucoseDate == nil {
                        lastBLEGlucoseDate = readings.last?.timestamp ?? Date()
                    }
                    updateTandemLiveSummaryBanner()
                    statusBanner = "Live t:slim X2 + G7 BLE · \(formatGlucose(cgmMgdL)) \(unit.rawValue) \(trend.arrow) · \(Self.shortTime(Date()))"
                } else {
                    updateTandemLiveSummaryBanner()
                }
            }

        case 37: // InsulinStatusResponse (4B: currentInsulinAmount[2], isEstimate[1], insulinLowAmount[1])
            if cargo.count >= 2 {
                let units = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
                pumpStatus.reservoirUnits = Double(units)
                updateTandemLiveSummaryBanner()
            }

        case 41: // CurrentBasalStatusResponse (9B: profileBasalRate[4], currentBasalRate[4], basalModifiedBitmask[1])
            if cargo.count >= 8 {
                let profileRaw = UInt32(cargo[0]) | (UInt32(cargo[1]) << 8) | (UInt32(cargo[2]) << 16) | (UInt32(cargo[3]) << 24)
                let currentRaw = UInt32(cargo[4]) | (UInt32(cargo[5]) << 8) | (UInt32(cargo[6]) << 16) | (UInt32(cargo[7]) << 24)
                pumpStatus.scheduledBasalRate = Double(profileRaw) / 1000.0
                pumpStatus.activeBasalRate = Double(currentRaw) / 1000.0
                pumpStatus.controlIQMode = "Control-IQ Active (BLE)"
                updateTandemLiveSummaryBanner()
            }

        case 49, 165: // LastBolusStatusResponse (49, 20B) / LastBolusStatusV2Response (165, 24B)
            if cargo.count >= 16, cargo[0] == 0 {
                let bolusId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
                let tsSec = UInt32(cargo[5]) | (UInt32(cargo[6]) << 8) | (UInt32(cargo[7]) << 16) | (UInt32(cargo[8]) << 24)
                let deliveredRaw = UInt32(cargo[9]) | (UInt32(cargo[10]) << 8) | (UInt32(cargo[11]) << 16) | (UInt32(cargo[12]) << 24)
                let units = Double(deliveredRaw) / 1000.0
                if units > 0 && units < 50 {
                    let rawDate = Date(timeIntervalSince1970: Jan1_2008_Epoch + TimeInterval(tsSec))
                    let bolusDate = abs(Date().timeIntervalSince(rawDate)) <= 7 * 86400 ? min(Date(), rawDate) : Date()
                    pumpStatus.lastBolusUnits = units
                    pumpStatus.lastBolusDate = bolusDate
                    let evId = "tandem-ble-bolus-\(bolusId)"
                    if !pumpEvents.contains(where: { $0.id == evId }) {
                        let sourceId = cargo[14]
                        let evType: PumpEventType = (sourceId == 7) ? .autoCorrection : .mealBolus
                        let ev = PumpEvent(
                            id: evId,
                            type: evType,
                            timestamp: bolusDate,
                            insulinUnits: units,
                            carbsGrams: nil,
                            basalRate: nil,
                            note: sourceId == 7 ? "Control-IQ Auto Bolus (t:slim X2 BLE)" : "Bolus delivered (t:slim X2 BLE)"
                        )
                        pumpEvents.insert(ev, at: 0)
                        pumpEvents.sort { $0.timestamp > $1.timestamp }
                    }
                    updateTandemLiveSummaryBanner()
                }
            }

        case 53: // CurrentBatteryV1Response (2B: currentBatteryAbc[1], currentBatteryIbc[1])
            if cargo.count >= 2 {
                let pct = Int(cargo[1])
                if (1...100).contains(pct) {
                    pumpStatus.batteryPercent = pct
                    updateTandemLiveSummaryBanner()
                }
            }

        case 57: // HomeScreenMirrorResponse (9B)
            if cargo.count >= 7 {
                let apState = cargo[6]
                if apState == 1 {
                    pumpStatus.controlIQMode = "Control-IQ Active (BLE)"
                } else if apState == 2 {
                    pumpStatus.controlIQMode = "Control-IQ Sleep (BLE)"
                } else if apState == 3 {
                    pumpStatus.controlIQMode = "Control-IQ Exercise (BLE)"
                }
                updateTandemLiveSummaryBanner()
            }

        case 61: // CGMStatusResponse (11B)
            updateTandemLiveSummaryBanner()

        case 109: // ControlIQIOBResponse (17B: mudaliarIOB[4], timeRemaining[4], totalIOB[4], swan6hrIOB[4], iobType[1])
            if cargo.count >= 16 {
                let mudaliarRaw = UInt32(cargo[0]) | (UInt32(cargo[1]) << 8) | (UInt32(cargo[2]) << 16) | (UInt32(cargo[3]) << 24)
                let swanRaw = UInt32(cargo[12]) | (UInt32(cargo[13]) << 8) | (UInt32(cargo[14]) << 16) | (UInt32(cargo[15]) << 24)
                let activeRaw = swanRaw > 0 ? swanRaw : mudaliarRaw
                pumpStatus.iobUnits = Double(activeRaw) / 1000.0
                pumpStatus.controlIQMode = "Control-IQ Active (BLE)"
                updateTandemLiveSummaryBanner()
            }

        default:
            updateTandemLiveSummaryBanner()
        }

        // Immediately send next queued status request if available
        if !tandemRequestQueue.isEmpty {
            sendNextTandemStatusRequest(on: peripheral)
        } else {
            tandemRequestInFlight = false
        }
    }

    @MainActor
    private func startG7AuthHandshakeIfNeeded(peripheral: CBPeripheral) {
        guard !g7InitialPacketSent, let authCh = g7AuthChar else { return }
        if let initial = g7Authenticator.makeInitialControlPacket() {
            g7InitialPacketSent = true
            g7UsingFullBootstrap = initial.isFullBootstrap
            g7BLEStatus = initial.isFullBootstrap
                ? "G7 J-PAKE ownership pairing started with \(g7BLEConnectedName) (Code \(g7PairingCode))…"
                : "G7 fast AES-128 auth started with \(g7BLEConnectedName)…"
            writeG7AuthControl(initial.packet, to: authCh, on: peripheral)
        } else {
            g7InitialPacketSent = true
            if let ctrl = g7ControlChar, !ctrl.isNotifying {
                peripheral.setNotifyValue(true, for: ctrl)
            }
            g7BLEStatus = "Connected to \(g7BLEConnectedName) · Enter 4-digit G7 Pairing Code (Tandem Pump: Options → My CGM)!"
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
        if let phase = g7PendingPakePhase, g7AuthStreamBuffer.count >= 160 {
            let payload = Data(g7AuthStreamBuffer.prefix(160))
            g7AuthStreamBuffer.removeFirst(160)
            g7PendingPakePhase = nil
            if let res = g7Authenticator.handlePakePhase(phase, payload: payload) {
                g7BLEStatus = "G7 J-PAKE Phase \(phase + 1)/3 verified with \(g7BLEConnectedName)…"
                writeG7StreamExchange(streamPackets: res.streamPackets, controlPacket: res.controlPacket, on: peripheral)
            } else {
                g7BLEStatus = "G7 J-PAKE Phase \(phase) failed — check 4-digit G7 Pairing Code!"
            }
        }

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

        if charUUID == Self.tandemCurrentStatusCharUUID || charUUID == Self.tandemControlCharUUID {
            Task { @MainActor in
                let p = self.canonicalPeripheral(peripheral)
                self.handleTandemCurrentStatusNotification(bytes, from: p)
            }
            return
        }

        if charUUID == Self.tandemAuthCharUUID {
            Task { @MainActor in
                let p = self.canonicalPeripheral(peripheral)
                self.handleTandemAuthNotification(bytes, from: p)
            }
            return
        }

        if charUUID == Self.tandemQualifyingEventsCharUUID {
            Task { @MainActor in
                let p = self.canonicalPeripheral(peripheral)
                self.requestTandemLiveStatus(on: p)
            }
            return
        }

        if charUUID == Self.disSerialNumberCharUUID || charUUID == Self.disSoftwareRevCharUUID || charUUID == Self.disModelNumberCharUUID {
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespacesAndNewlines)), !str.isEmpty {
                Task { @MainActor in
                    if charUUID == Self.disSerialNumberCharUUID {
                        self.pumpStatus.pumpSerialNumber = "tslim X2 #\(str)"
                        if self.tandemPumpSerial.isEmpty {
                            self.tandemPumpSerial = str
                        }
                    } else if charUUID == Self.disSoftwareRevCharUUID && !self.tandemConnected {
                        self.tandemBLEStatus = "Connected to \(self.pumpStatus.pumpSerialNumber) (FW \(str)) · Querying telemetry…"
                    }
                }
            }
            return
        }

        if charUUID == Self.batteryLevelCharUUID, let pct = bytes.first, (1...100).contains(Int(pct)) {
            Task { @MainActor in
                self.pumpStatus.batteryPercent = Int(pct)
            }
            return
        }

        if charUUID == Self.g7AuthStreamCharUUID {
            Task { @MainActor in
                let p = self.canonicalPeripheral(peripheral)
                self.g7AuthStreamBuffer.append(data)
                self.processPendingG7AuthStreams(peripheral: p)
            }
            return
        }

        if charUUID == Self.g7AuthCharUUID {
            Task { @MainActor in
                let p = self.canonicalPeripheral(peripheral)
                guard let authCh = self.g7AuthChar else { return }
                let op = bytes[0]

                switch op {
                case 0x03: // AuthRequestRx (17 bytes: 0x03 + 8B tokenHash + 8B challenge)
                    guard !self.g7ChallengeResponseSent, data.count >= 17 else { return }
                    let challenge = data.subdata(in: 9..<17)
                    if let resp = self.g7Authenticator.makeChallengeResponse(challenge: challenge) {
                        self.g7ChallengeResponseSent = true
                        self.g7BLEStatus = "G7 AES-128 challenge answered for \(self.g7BLEConnectedName)…"
                        self.writeG7AuthControl(resp, to: authCh, on: p)
                    } else {
                        self.g7BLEStatus = "\(self.g7BLEConnectedName) requested auth — enter 4-digit G7 Pairing Code (Tandem Pump: Options → My CGM)!"
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
                                    self.writeG7AuthControl(cert0, to: authCh, on: p)
                                }
                            }
                        } else if isPaired {
                            self.onG7Authenticated(peripheral: p)
                        } else {
                            self.g7Authenticator.clearSharedKey()
                            self.g7BLEStatus = "G7 slot needs full bootstrap — reconnecting \(self.g7BLEConnectedName)…"
                        }
                    } else {
                        self.g7BLEStatus = "\(self.g7BLEConnectedName) unauthenticated — check 4-digit G7 Pairing Code (\(self.g7PairingCode))!"
                    }

                case 0x0A: // ExchangePakePayload (0x0A, 0x00, phase)
                    guard bytes.count >= 3, bytes[1] == 0x00 else {
                        self.g7BLEStatus = "G7 rejected J-PAKE — check 4-digit Pairing Code!"
                        return
                    }
                    self.g7PendingPakePhase = bytes[2]
                    self.processPendingG7AuthStreams(peripheral: p)

                case 0x0B: // CertificateExchange (0x0B, 0x00, phase, sizeLE[4])
                    guard bytes.count >= 7, bytes[1] == 0x00 else { return }
                    let phase = bytes[2]
                    let size = Int(UInt32(bytes[3]) | (UInt32(bytes[4]) << 8) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 24))
                    guard size <= 4096 else { return }
                    self.g7PendingCertPhase = phase
                    self.g7PendingCertSize = size
                    self.processPendingG7AuthStreams(peripheral: p)

                case 0x0C: // ProofOfPossession (0x0C, 0x00, challenge[16])
                    guard data.count >= 18, bytes[1] == 0x00 else { return }
                    self.g7PendingProofChallenge = data.subdata(in: 2..<18)
                    self.processPendingG7AuthStreams(peripheral: p)

                case 0x0D: // AuthStatusTx ack -> send keep-alive 0x06 0x19
                    self.writeG7AuthControl(Data([0x06, 0x19]), to: authCh, on: p)

                case 0x06: // KeepAlive response (0x06 0x01 = complete, 0x06 0x00 = request bond 0x07)
                    if bytes.count >= 2 && bytes[1] == 0x01 {
                        self.g7Authenticator.confirmAndPersistSharedKey()
                        self.onG7Authenticated(peripheral: p)
                    } else if bytes.count >= 2 && bytes[1] == 0x00 {
                        self.g7BLEStatus = "G7 requesting iOS Bluetooth Bond — tap 'Pair' if prompted!"
                        self.writeG7AuthControl(Data([0x07]), to: authCh, on: p)
                    }

                case 0x08: // PairRequestRx (0x08 0x01 = bonded!)
                    if bytes.count >= 2 && bytes[1] == 0x01 {
                        self.g7Authenticator.confirmAndPersistSharedKey()
                        self.onG7Authenticated(peripheral: p)
                    }

                default:
                    break
                }
            }
            return
        }

        if charUUID == Self.g7ControlCharUUID {
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
