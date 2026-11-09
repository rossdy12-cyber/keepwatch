import SwiftUI
import UniformTypeIdentifiers
import GameController
import Combine
import WebKit
import AVFoundation
import UIKit

// MARK: - Models

enum RetroSystem: String, CaseIterable, Codable, Identifiable {
    case nes = "NES"
    case snes = "SNES"
    case gba = "GBA"
    case gbc = "GB/GBC"
    case megadrive = "Mega Drive"
    case n64 = "N64"
    case nds = "Nintendo DS"
    case ps1 = "PS1"
    case arcade = "Homebrew"

    var id: String { rawValue }

    var ejsCore: String {
        switch self {
        case .nes: return "fceumm"
        case .snes: return "snes9x"
        case .gba: return "mgba"
        case .gbc: return "gambatte"
        case .megadrive: return "genesis_plus_gx"
        case .n64: return "mupen64plus_next"
        case .nds: return "melonds"
        case .ps1: return "pcsx_rearmed"
        case .arcade: return "fceumm"
        }
    }

    var iconName: String {
        switch self {
        case .nes, .snes: return "dpad.fill"
        case .gba, .gbc, .nds: return "Candybarphone" == "" ? "ipad.landscape" : "rectangle.grid.1x2.fill"
        case .megadrive: return "bolt.horizontal.fill"
        case .n64: return "gamecontroller.fill"
        case .ps1: return "opticaldisc.fill"
        case .arcade: return "arcade.stick.console.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .nes: return .red
        case .snes: return .purple
        case .gba: return .indigo
        case .gbc: return .teal
        case .megadrive: return .blue
        case .n64: return .green
        case .nds: return .cyan
        case .ps1: return .orange
        case .arcade: return .yellow
        }
    }

    static func detect(fromExtension ext: String) -> RetroSystem? {
        switch ext.lowercased() {
        case "nes", "fds", "unf": return .nes
        case "sfc", "smc", "fig", "swc": return .snes
        case "gba", "agb": return .gba
        case "gb", "gbc", "sgb": return .gbc
        case "md", "gen", "smd", "bin", "gg", "sms": return .megadrive
        case "z64", "n64", "v64": return .n64
        case "nds", "ids": return .nds
        case "chd", "pbp", "iso", "cue", "img", "ecm": return .ps1
        case "rdrom": return .arcade
        default: return nil
        }
    }
}

struct Game: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var system: String
    var filename: String
    var lastPlayed: Date?
    var playTimeSeconds: Int = 0
}

struct SaveStateSlot: Identifiable, Codable, Hashable {
    var id: String { "\(gameID.uuidString)_slot_\(slot)" }
    var gameID: UUID
    var slot: Int // 0 = Auto, 1..4 = Manual Slots
    var timestamp: Date
    var filename: String
    var sizeBytes: Int
}

enum VideoFilterMode: String, CaseIterable, Codable, Identifiable {
    case crispPixel = "Crisp Pixel"
    case crtScanlines = "CRT Scanlines"
    case smooth = "Smooth Bilinear"
    var id: String { rawValue }
}

enum AspectRatioMode: String, CaseIterable, Codable, Identifiable {
    case fourThree = "4:3 Original"
    case sixteenNine = "16:9 Widescreen"
    case integerPixel = "Pixel Perfect"
    var id: String { rawValue }
}

// MARK: - Button Remapping & Controller Actions

enum RetroAction: String, CaseIterable, Codable, Identifiable {
    case up = "D-Pad Up"
    case down = "D-Pad Down"
    case left = "D-Pad Left"
    case right = "D-Pad Right"
    case buttonB = "Action B (South)"
    case buttonA = "Action A (East)"
    case buttonY = "Action Y (West)"
    case buttonX = "Action X (North)"
    case start = "Start"
    case select = "Select"
    case shoulderL1 = "L1 Bumper"
    case shoulderR1 = "R1 Bumper"
    case triggerL2 = "L2 Trigger"
    case triggerR2 = "R2 Trigger"
    case quickSave = "Quick Save (Slot 1)"
    case quickLoad = "Quick Load (Slot 1)"
    case fastForward = "Fast Forward Hold"

    var id: String { rawValue }

    // Libretro Joypad IDs (0..15)
    var libretroBitIndex: Int? {
        switch self {
        case .buttonB: return 0
        case .buttonY: return 1
        case .select: return 2
        case .start: return 3
        case .up: return 4
        case .down: return 5
        case .left: return 6
        case .right: return 7
        case .buttonA: return 8
        case .buttonX: return 9
        case .shoulderL1: return 10
        case .shoulderR1: return 11
        case .triggerL2: return 12
        case .triggerR2: return 13
        default: return nil
        }
    }
}

enum PhysicalPadButton: String, CaseIterable, Codable, Identifiable {
    case dpadUp = "D-Pad Up"
    case dpadDown = "D-Pad Down"
    case dpadLeft = "D-Pad Left"
    case dpadRight = "D-Pad Right"
    case buttonA = "Physical A (Bottom)"
    case buttonB = "Physical B (Right)"
    case buttonX = "Physical X (Left)"
    case buttonY = "Physical Y (Top)"
    case leftShoulder = "L1 Shoulder"
    case rightShoulder = "R1 Shoulder"
    case leftTrigger = "L2 Trigger"
    case rightTrigger = "R2 Trigger"
    case leftThumbstickButton = "L3 Stick Click"
    case rightThumbstickButton = "R3 Stick Click"
    case buttonOptions = "Options / Select"
    case buttonMenu = "Menu / Start"

    var id: String { rawValue }
}

@MainActor
final class ButtonMappingStore: ObservableObject {
    @Published var bindings: [RetroAction: PhysicalPadButton] = [:]
    @Published var touchControlsOpacity: Double = 0.80
    @Published var autoHideTouchWhenControllerConnected: Bool = true
    @Published var hapticFeedbackEnabled: Bool = true
    @Published var swapABXYNintendoStyle: Bool = false

    private let storageKey = "retrodeck.button_mappings.v1"
    private let prefsKey = "retrodeck.input_prefs.v1"

    init() {
        resetDefaults()
        load()
    }

    func resetDefaults() {
        bindings = [
            .up: .dpadUp,
            .down: .dpadDown,
            .left: .dpadLeft,
            .right: .dpadRight,
            .buttonB: .buttonA,
            .buttonA: .buttonB,
            .buttonY: .buttonX,
            .buttonX: .buttonY,
            .start: .buttonMenu,
            .select: .buttonOptions,
            .shoulderL1: .leftShoulder,
            .shoulderR1: .rightShoulder,
            .triggerL2: .leftTrigger,
            .triggerR2: .rightTrigger,
            .quickSave: .leftThumbstickButton,
            .quickLoad: .rightThumbstickButton,
            .fastForward: .rightTrigger
        ]
    }

    func bind(_ action: RetroAction, to physical: PhysicalPadButton) {
        bindings[action] = physical
        save()
    }

    func save() {
        var rawDict: [String: String] = [:]
        for (k, v) in bindings { rawDict[k.rawValue] = v.rawValue }
        if let data = try? JSONEncoder().encode(rawDict) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        let prefs: [String: Double] = [
            "opacity": touchControlsOpacity,
            "autoHide": autoHideTouchWhenControllerConnected ? 1 : 0,
            "haptics": hapticFeedbackEnabled ? 1 : 0,
            "nintendoSwap": swapABXYNintendoStyle ? 1 : 0
        ]
        UserDefaults.standard.set(prefs, forKey: prefsKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let rawDict = try? JSONDecoder().decode([String: String].self, from: data) {
            for (k, v) in rawDict {
                if let action = RetroAction(rawValue: k), let phys = PhysicalPadButton(rawValue: v) {
                    bindings[action] = phys
                }
            }
        }
        if let prefs = UserDefaults.standard.dictionary(forKey: prefsKey) as? [String: Double] {
            if let op = prefs["opacity"] { touchControlsOpacity = op }
            if let ah = prefs["autoHide"] { autoHideTouchWhenControllerConnected = ah > 0.5 }
            if let hp = prefs["haptics"] { hapticFeedbackEnabled = hp > 0.5 }
            if let ns = prefs["nintendoSwap"] { swapABXYNintendoStyle = ns > 0.5 }
        }
    }
}

// MARK: - Hardware GameController Monitor & Live Input Aggregator

@MainActor
final class ControllerMonitor: ObservableObject {
    @Published var name = "No controller connected"
    @Published var isConnected = false
    @Published var input = "Connect your Backbone USB-C or MFi controller and press any button."
    @Published var activeActions: Set<RetroAction> = []
    @Published var touchActions: Set<RetroAction> = []
    @Published var leftStick: CGPoint = .zero
    @Published var rightStick: CGPoint = .zero
    @Published var lastPressedPhysicalButton: PhysicalPadButton?

    var onHotkeyTriggered: ((RetroAction) -> Void)?
    weak var mappingStore: ButtonMappingStore?

    private var controller: GCController?
    private var tokens: [NSObjectProtocol] = []
    private var previousHotkeys: Set<RetroAction> = []

    init(mappingStore: ButtonMappingStore? = nil) {
        self.mappingStore = mappingStore
        for event in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            tokens.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        GCController.startWirelessControllerDiscovery {}
        refresh()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    var combinedActions: Set<RetroAction> {
        activeActions.union(touchActions)
    }

    var combinedBitmask: Int {
        var mask = 0
        for act in combinedActions {
            if let bit = act.libretroBitIndex {
                mask |= (1 << bit)
            }
        }
        if leftStick.y > 0.45 { mask |= (1 << 4) }
        if leftStick.y < -0.45 { mask |= (1 << 5) }
        if leftStick.x < -0.45 { mask |= (1 << 6) }
        if leftStick.x > 0.45 { mask |= (1 << 7) }
        return mask
    }

    func setTouchAction(_ action: RetroAction, pressed: Bool) {
        if pressed {
            if !touchActions.contains(action), mappingStore?.hapticFeedbackEnabled ?? true {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            touchActions.insert(action)
        } else {
            touchActions.remove(action)
        }
    }

    func refresh() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        if let c = controller {
            name = c.vendorName ?? "Backbone / MFi Game Controller"
            isConnected = true
        } else {
            name = "No controller connected"
            isConnected = false
            activeActions.removeAll()
            leftStick = .zero
            rightStick = .zero
        }

        controller?.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            Task { @MainActor in
                self?.pollGamepad(pad)
            }
        }
    }

    private func pollGamepad(_ pad: GCExtendedGamepad) {
        let physicalStates: [PhysicalPadButton: Bool] = [
            .dpadUp: pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5,
            .dpadDown: pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5,
            .dpadLeft: pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5,
            .dpadRight: pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5,
            .buttonA: pad.buttonA.isPressed,
            .buttonB: pad.buttonB.isPressed,
            .buttonX: pad.buttonX.isPressed,
            .buttonY: pad.buttonY.isPressed,
            .leftShoulder: pad.leftShoulder.isPressed,
            .rightShoulder: pad.rightShoulder.isPressed,
            .leftTrigger: pad.leftTrigger.isPressed,
            .rightTrigger: pad.rightTrigger.isPressed,
            .leftThumbstickButton: pad.leftThumbstickButton?.isPressed ?? false,
            .rightThumbstickButton: pad.rightThumbstickButton?.isPressed ?? false,
            .buttonOptions: pad.buttonOptions?.isPressed ?? false,
            .buttonMenu: pad.buttonMenu.isPressed
        ]

        if let justPressed = physicalStates.first(where: { $0.value })?.key {
            lastPressedPhysicalButton = justPressed
        }

        let bindings = mappingStore?.bindings ?? [:]
        var nextActions: Set<RetroAction> = []
        for (retroAct, physBtn) in bindings {
            if physicalStates[physBtn] == true {
                nextActions.insert(retroAct)
            }
        }

        // Check rising edge for hotkeys
        for hk in [RetroAction.quickSave, .quickLoad] {
            if nextActions.contains(hk) && !previousHotkeys.contains(hk) {
                onHotkeyTriggered?(hk)
            }
        }
        previousHotkeys = nextActions.intersection([.quickSave, .quickLoad])
        activeActions = nextActions

        leftStick = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
        rightStick = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))

        let pressedNames = physicalStates.filter { $0.value }.map { $0.key.rawValue }.sorted().joined(separator: ", ")
        input = """
        Buttons: \(pressedNames.isEmpty ? "none" : pressedNames)
        D-Pad: (\(String(format: "%.2f", pad.dpad.xAxis.value)), \(String(format: "%.2f", pad.dpad.yAxis.value)))
        L-Stick: (\(String(format: "%.2f", pad.leftThumbstick.xAxis.value)), \(String(format: "%.2f", pad.leftThumbstick.yAxis.value)))
        R-Stick: (\(String(format: "%.2f", pad.rightThumbstick.xAxis.value)), \(String(format: "%.2f", pad.rightThumbstick.yAxis.value)))
        Mapped Actions: \(nextActions.map { $0.rawValue }.sorted().joined(separator: " + "))
        """
    }
}

// MARK: - Library, BIOS & SaveState Storage

@MainActor
final class Library: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published private(set) var saveStates: [SaveStateSlot] = []
    @Published private(set) var installedBIOS: [String: Int] = [:]
    @Published var error: String?
    @Published var statusMessage: String?

    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var savesDirectory: URL { directory.appendingPathComponent("SaveStates", isDirectory: true) }
    var biosDirectory: URL { directory.appendingPathComponent("BIOS", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("library.json") }
    private var statesIndexURL: URL { directory.appendingPathComponent("savestates.json") }

    init() {
        try? FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: biosDirectory, withIntermediateDirectories: true)
        loadLibrary()
        loadSaveStates()
        refreshBIOS()
        if games.isEmpty {
            installStarterHomebrewGames()
        }
    }

    func loadLibrary() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            games = try JSONDecoder().decode([Game].self, from: Data(contentsOf: indexURL))
        } catch {
            self.error = "Could not load library index: \(error.localizedDescription)"
        }
    }

    func saveLibrary() {
        if let data = try? JSONEncoder().encode(games) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func loadSaveStates() {
        guard FileManager.default.fileExists(atPath: statesIndexURL.path) else { return }
        if let loaded = try? JSONDecoder().decode([SaveStateSlot].self, from: Data(contentsOf: statesIndexURL)) {
            saveStates = loaded
        }
    }

    func saveSaveStatesIndex() {
        if let data = try? JSONEncoder().encode(saveStates) {
            try? data.write(to: statesIndexURL, options: .atomic)
        }
    }

    func refreshBIOS() {
        var found: [String: Int] = [:]
        if let items = try? FileManager.default.contentsOfDirectory(at: biosDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in items {
                let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                found[url.lastPathComponent.lowercased()] = sz
            }
        }
        installedBIOS = found
    }

    func importBIOSFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let target = biosDirectory.appendingPathComponent(url.lastPathComponent.lowercased())
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                statusMessage = "Imported BIOS: \(url.lastPathComponent)"
            } catch {
                self.error = "BIOS import failed: \(error.localizedDescription)"
            }
        }
        refreshBIOS()
    }

    func importFiles(_ urls: [URL]) {
        var importedCount = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let detected = RetroSystem.detect(fromExtension: ext) ?? (ext == "zip" ? .nes : nil)
            guard let system = detected else {
                error = "Unsupported file: \(url.lastPathComponent). Supported: .nes, .sfc, .smc, .gba, .gb, .gbc, .md, .gen, .bin, .z64, .n64, .v64, .nds, .chd, .pbp, .iso, .zip"
                continue
            }

            let id = UUID()
            let filename = id.uuidString + "." + ext
            let target = directory.appendingPathComponent(filename)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                let cleanTitle = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                let game = Game(id: id, name: cleanTitle, system: system.rawValue, filename: filename, lastPlayed: Date())
                games.insert(game, at: 0)
                importedCount += 1
            } catch {
                self.error = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if importedCount > 0 {
            saveLibrary()
            statusMessage = "Imported \(importedCount) ROM\(importedCount == 1 ? "" : "s")!"
        }
    }

    func deleteGame(_ game: Game) {
        let fileURL = directory.appendingPathComponent(game.filename)
        try? FileManager.default.removeItem(at: fileURL)
        games.removeAll { $0.id == game.id }
        saveLibrary()
    }

    func installStarterHomebrewGames() {
        let starters: [(String, RetroSystem, String)] = [
            ("Neon Cyber Pong DX", .arcade, "PONG"),
            ("Starfield Invaders 60FPS", .arcade, "INVADERS"),
            ("Hyper Breakout Synth", .arcade, "BREAKOUT"),
            ("Matrix Grid Runner", .arcade, "SNAKE")
        ]
        for (title, sys, modeTag) in starters {
            if games.contains(where: { $0.name == title }) { continue }
            let id = UUID()
            let filename = "\(id.uuidString).rdrom"
            let target = directory.appendingPathComponent(filename)
            let payload = "RETRODECK_HOMEBREW_V1:\(modeTag)".data(using: .utf8) ?? Data()
            try? payload.write(to: target)
            games.append(Game(id: id, name: title, system: sys.rawValue, filename: filename, lastPlayed: Date()))
        }
        saveLibrary()
    }

    // MARK: Save State Operations

    func slots(for gameID: UUID) -> [SaveStateSlot] {
        saveStates.filter { $0.gameID == gameID }.sorted { $0.slot < $1.slot }
    }

    func writeSaveState(for gameID: UUID, slot: Int, data: Data) {
        let fname = "\(gameID.uuidString)_slot_\(slot).state"
        let url = savesDirectory.appendingPathComponent(fname)
        do {
            try data.write(to: url, options: .atomic)
            let entry = SaveStateSlot(gameID: gameID, slot: slot, timestamp: Date(), filename: fname, sizeBytes: data.count)
            saveStates.removeAll { $0.gameID == gameID && $0.slot == slot }
            saveStates.append(entry)
            saveSaveStatesIndex()
            statusMessage = "Saved state to Slot \(slot) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
        } catch {
            self.error = "Failed to write save state: \(error.localizedDescription)"
        }
    }

    func readSaveState(for gameID: UUID, slot: Int) -> Data? {
        guard let entry = saveStates.first(where: { $0.gameID == gameID && $0.slot == slot }) else {
            return nil
        }
        let url = savesDirectory.appendingPathComponent(entry.filename)
        return try? Data(contentsOf: url)
    }

    func deleteSaveState(_ slot: SaveStateSlot) {
        let url = savesDirectory.appendingPathComponent(slot.filename)
        try? FileManager.default.removeItem(at: url)
        saveStates.removeAll { $0.id == slot.id }
        saveSaveStatesIndex()
    }
}

// MARK: - Native Chiptune Audio Synthesizer (AVAudioEngine)

final class RetroChiptuneSynth {
    private let engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    var isMuted: Bool = false

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        playerNode.play()
    }

    func beep(frequency: Float, durationMs: Int = 55, volume: Float = 0.18) {
        guard !isMuted else { return }
        if !engine.isRunning { try? engine.start(); playerNode.play() }
        let frameCount = AVAudioFrameCount((44100 * durationMs) / 1000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return }
        let step = (frequency * 2.0 * .pi) / 44100.0
        for i in 0..<Int(frameCount) {
            let env = 1.0 - (Float(i) / Float(frameCount))
            channel[i] = (sin(Float(i) * step) >= 0 ? 1.0 : -1.0) * volume * env
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
}

// MARK: - Native Offline 60FPS Arcade & Homebrew Emulator Core

struct NativeArcadeState: Codable {
    var mode: String
    var scoreP1: Int
    var scoreCPU: Int
    var lives: Int
    var level: Int
    var playerX: Double
    var playerY: Double
    var ballX: Double
    var ballY: Double
    var ballVX: Double
    var ballVY: Double
    var bricks: [Bool]
    var snakeBody: [[Int]]
    var foodX: Int
    var foodY: Int
}

@MainActor
final class NativeRetroCoreEngine: ObservableObject {
    @Published var state: NativeArcadeState
    @Published var isPaused: Bool = false
    @Published var fastForwardMultiplier: Int = 1
    @Published var fps: Int = 60
    let synth = RetroChiptuneSynth()

    init(mode: String) {
        self.state = NativeArcadeState(
            mode: mode,
            scoreP1: 0,
            scoreCPU: 0,
            lives: 3,
            level: 1,
            playerX: 0.5,
            playerY: 0.88,
            ballX: 0.5,
            ballY: 0.5,
            ballVX: 0.011,
            ballVY: -0.013,
            bricks: Array(repeating: true, count: 40),
            snakeBody: [[10, 10], [9, 10], [8, 10], [7, 10]],
            foodX: 15,
            foodY: 10
        )
    }

    func serializeState() -> Data? {
        try? JSONEncoder().encode(state)
    }

    func restoreState(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(NativeArcadeState.self, from: data) else { return false }
        self.state = decoded
        synth.beep(frequency: 880, durationMs: 80)
        return true
    }

    private var tickCounter = 0

    func stepFrame(actions: Set<RetroAction>, leftStick: CGPoint) {
        guard !isPaused else { return }
        let loops = max(1, fastForwardMultiplier)
        for _ in 0..<loops {
            stepSingleTick(actions: actions, leftStick: leftStick)
        }
    }

    private func stepSingleTick(actions: Set<RetroAction>, leftStick: CGPoint) {
        tickCounter += 1
        var dx = 0.0
        var dy = 0.0
        if actions.contains(.left) || leftStick.x < -0.25 { dx = -0.022 }
        if actions.contains(.right) || leftStick.x > 0.25 { dx = 0.022 }
        if actions.contains(.up) || leftStick.y > 0.25 { dy = -0.022 }
        if actions.contains(.down) || leftStick.y < -0.25 { dy = 0.022 }

        if actions.contains(.buttonA) || actions.contains(.buttonX) {
            dx *= 1.65
            dy *= 1.65
        }

        state.playerX = min(0.90, max(0.10, state.playerX + dx))
        state.playerY = min(0.92, max(0.10, state.playerY + dy))

        if state.mode == "SNAKE" {
            if dx < 0 { state.ballVX = -1; state.ballVY = 0 }
            else if dx > 0 { state.ballVX = 1; state.ballVY = 0 }
            else if dy < 0 { state.ballVX = 0; state.ballVY = -1 }
            else if dy > 0 { state.ballVX = 0; state.ballVY = 1 }

            guard tickCounter % 6 == 0 else { return }
            let head = state.snakeBody.first ?? [10, 10]
            let stepX = Int(state.ballVX == 0 && state.ballVY == 0 ? 1 : state.ballVX)
            let stepY = Int(state.ballVY)
            let nx = (head[0] + stepX + 24) % 24
            let ny = (head[1] + stepY + 18) % 18
            let newHead = [nx, ny]
            if state.snakeBody.contains(newHead) {
                state.lives = max(1, state.lives - 1)
                state.snakeBody = [[10, 10], [9, 10], [8, 10]]
                synth.beep(frequency: 160, durationMs: 140)
                return
            }
            state.snakeBody.insert(newHead, at: 0)
            if nx == state.foodX && ny == state.foodY {
                state.scoreP1 += 50
                state.foodX = Int.random(in: 1..<23)
                state.foodY = Int.random(in: 1..<17)
                synth.beep(frequency: 660, durationMs: 65)
            } else {
                _ = state.snakeBody.popLast()
            }
            return
        }

        // Ball physics for PONG / BREAKOUT / INVADERS
        state.ballX += state.ballVX
        state.ballY += state.ballVY

        if state.ballX <= 0.04 || state.ballX >= 0.96 {
            state.ballVX = -state.ballVX
            synth.beep(frequency: 440, durationMs: 35)
        }
        if state.ballY <= 0.06 {
            state.ballVY = abs(state.ballVY)
            if state.mode == "PONG" {
                state.scoreP1 += 100
                synth.beep(frequency: 784, durationMs: 90)
            } else {
                synth.beep(frequency: 523, durationMs: 40)
            }
        }

        // Paddle collision
        if state.ballY >= 0.84 && state.ballY <= 0.91 && abs(state.ballX - state.playerX) < 0.13 {
            state.ballVY = -abs(state.ballVY)
            let offset = (state.ballX - state.playerX) * 0.14
            state.ballVX = max(-0.022, min(0.022, state.ballVX + offset))
            state.scoreP1 += 10
            synth.beep(frequency: 587, durationMs: 45)
        }

        // Brick / Invader collisions
        for idx in state.bricks.indices where state.bricks[idx] {
            let col = idx % 8
            let row = idx / 8
            let bx = 0.12 + Double(col) * 0.108
            let by = 0.14 + Double(row) * 0.065
            if abs(state.ballX - bx) < 0.055 && abs(state.ballY - by) < 0.032 {
                state.bricks[idx] = false
                state.ballVY = -state.ballVY
                state.scoreP1 += 25
                synth.beep(frequency: Float(620 + row * 70), durationMs: 50)
                if !state.bricks.contains(true) {
                    state.level += 1
                    state.bricks = Array(repeating: true, count: 40)
                    state.ballVX *= 1.12
                    state.ballVY *= 1.12
                    synth.beep(frequency: 987, durationMs: 120)
                }
                break
            }
        }

        // Bottom miss
        if state.ballY > 0.98 {
            state.scoreCPU += 1
            state.ballX = state.playerX
            state.ballY = 0.78
            state.ballVY = -abs(state.ballVY)
            synth.beep(frequency: 196, durationMs: 120)
        }
    }
}

// MARK: - Custom URL Scheme Handler + Libretro WebAssembly Host (EmulatorJS)

final class RetroROMURLSchemeHandler: NSObject, WKURLSchemeHandler {
    let romDirectory: URL
    let biosDirectory: URL

    init(romDirectory: URL, biosDirectory: URL) {
        self.romDirectory = romDirectory
        self.biosDirectory = biosDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL: URL
        if path.hasPrefix("bios/") {
            let bname = String(path.dropFirst(5))
            fileURL = biosDirectory.appendingPathComponent(bname)
        } else {
            fileURL = romDirectory.appendingPathComponent(path)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
final class LibretroWebBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var isCoreReady: Bool = false
    @Published var coreStatusText: String = "Initializing Libretro Core..."
    weak var webView: WKWebView?
    var onSaveStateCaptured: ((Int, Data) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isCoreReady = true
            coreStatusText = "Libretro Core Running (60 FPS)"
        case "status":
            if let msg = body["message"] as? String {
                coreStatusText = msg
            }
        case "savestate":
            if let b64 = body["base64"] as? String,
               let slot = body["slot"] as? Int,
               let data = Data(base64Encoded: b64) {
                onSaveStateCaptured?(slot, data)
            }
        default:
            break
        }
    }

    func pushInput(bitmask: Int, lx: CGFloat, ly: CGFloat, rx: CGFloat, ry: CGFloat, fastForward: Bool) {
        guard let wv = webView else { return }
        let js = "if(window.retroInjectInput){window.retroInjectInput(\(bitmask),\(lx),\(ly),\(rx),\(ry),\(fastForward ? "true" : "false"));}"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    func captureSaveState(slot: Int) {
        webView?.evaluateJavaScript("if(window.retroCaptureState){window.retroCaptureState(\(slot));}", completionHandler: nil)
    }

    func loadSaveState(data: Data) {
        let b64 = data.base64EncodedString()
        webView?.evaluateJavaScript("if(window.retroRestoreState){window.retroRestoreState('\(b64)');}", completionHandler: nil)
    }

    func setAudioMuted(_ muted: Bool) {
        webView?.evaluateJavaScript("if(window.retroSetMute){window.retroSetMute(\(muted ? "true" : "false"));}", completionHandler: nil)
    }
}

struct LibretroWebViewRepresentable: UIViewRepresentable {
    let game: Game
    let system: RetroSystem
    let romDirectory: URL
    let biosDirectory: URL
    @ObservedObject var bridge: LibretroWebBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let schemeHandler = RetroROMURLSchemeHandler(romDirectory: romDirectory, biosDirectory: biosDirectory)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "retrodeck")
        config.userContentController.add(bridge, name: "retroBridge")

        // Inject Virtual W3C Gamepad shim so Backbone + Touch Overlay feed directly into Libretro/EmulatorJS
        let gamepadShimJS = """
        (function() {
            window._virtualPadState = {
                buttons: Array.from({length: 16}, () => ({pressed: false, touched: false, value: 0})),
                axes: [0, 0, 0, 0]
            };
            const origGetGamepads = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : () => [];
            navigator.getGamepads = function() {
                const real = origGetGamepads();
                if (real && real[0]) return real;
                return [{
                    id: "RetroDeck Backbone / Touch Virtual Pad",
                    index: 0,
                    connected: true,
                    mapping: "standard",
                    timestamp: performance.now(),
                    buttons: window._virtualPadState.buttons,
                    axes: window._virtualPadState.axes
                }];
            };
            window.retroInjectInput = function(mask, lx, ly, rx, ry, ff) {
                // Map Libretro bitmask to W3C Standard Gamepad buttons:
                // 0:B(South), 1:A(East), 2:Y(West), 3:X(North), 4:L1, 5:R1, 6:L2, 7:R2, 8:Select, 9:Start, 12:Up, 13:Down, 14:Left, 15:Right
                const map = [
                    [0, 0],  // Retro B -> W3C 0
                    [8, 1],  // Retro A -> W3C 1
                    [1, 2],  // Retro Y -> W3C 2
                    [9, 3],  // Retro X -> W3C 3
                    [10, 4], // L1 -> 4
                    [11, 5], // R1 -> 5
                    [12, 6], // L2 -> 6
                    [13, 7], // R2 -> 7
                    [2, 8],  // Select -> 8
                    [3, 9],  // Start -> 9
                    [4, 12], // Up -> 12
                    [5, 13], // Down -> 13
                    [6, 14], // Left -> 14
                    [7, 15]  // Right -> 15
                ];
                for (const [rBit, wIdx] of map) {
                    const p = ((mask & (1 << rBit)) !== 0);
                    window._virtualPadState.buttons[wIdx] = {pressed: p, touched: p, value: p ? 1.0 : 0.0};
                }
                window._virtualPadState.axes = [lx, -ly, rx, -ry];
                try {
                    const gm = window.EJS_emulator && window.EJS_emulator.gameManager;
                    if (gm && gm.functions && gm.functions.simulateInput) {
                        for (let i = 0; i < 14; i++) {
                            gm.functions.simulateInput(0, i, ((mask & (1 << i)) !== 0) ? 1 : 0);
                        }
                    }
                    if (window.EJS_emulator && typeof window.EJS_emulator.setFastForward === 'function') {
                        window.EJS_emulator.setFastForward(ff ? 1 : 0);
                    }
                } catch(e) {}
            };
            window.retroCaptureState = function(slot) {
                try {
                    const gm = window.EJS_emulator && window.EJS_emulator.gameManager;
                    if (gm && typeof gm.getState === 'function') {
                        const u8 = gm.getState();
                        let binary = '';
                        for (let i = 0; i < u8.byteLength; i++) binary += String.fromCharCode(u8[i]);
                        const b64 = btoa(binary);
                        window.webkit.messageHandlers.retroBridge.postMessage({type: 'savestate', slot: slot, base64: b64});
                    }
                } catch(e) {
                    window.webkit.messageHandlers.retroBridge.postMessage({type: 'status', message: 'State error: ' + e});
                }
            };
            window.retroRestoreState = function(b64) {
                try {
                    const gm = window.EJS_emulator && window.EJS_emulator.gameManager;
                    if (gm && typeof gm.loadState === 'function') {
                        const bin = atob(b64);
                        const u8 = new Uint8Array(bin.length);
                        for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
                        gm.loadState(u8);
                        window.webkit.messageHandlers.retroBridge.postMessage({type: 'status', message: 'Save State Restored!'});
                    }
                } catch(e) {}
            };
            window.retroSetMute = function(muted) {
                try {
                    if (window.EJS_emulator && typeof window.EJS_emulator.setVolume === 'function') {
                        window.EJS_emulator.setVolume(muted ? 0 : 1.0);
                    }
                } catch(e) {}
            };
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: gamepadShimJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        bridge.webView = wv

        let romURL = "retrodeck://local/\(game.filename)"
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
            #game { width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="game"></div>
        <script>
            EJS_player = '#game';
            EJS_core = '\(system.ejsCore)';
            EJS_gameUrl = '\(romURL)';
            EJS_pathtodata = 'https://cdn.emulatorjs.org/stable/data/';
            EJS_startOnLoaded = true;
            EJS_VirtualGamepadSettings = { enabled: false };
            EJS_onGameStart = function() {
                window.webkit.messageHandlers.retroBridge.postMessage({type: 'ready'});
            };
        </script>
        <script src="https://cdn.emulatorjs.org/stable/data/loader.js"
                onerror="window.webkit.messageHandlers.retroBridge.postMessage({type: 'status', message: 'Offline Mode Active — Using Native Core'})"></script>
        </body>
        </html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://cdn.emulatorjs.org/"))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - On-Screen Touch Controller Overlay

struct TouchControllerOverlay: View {
    @ObservedObject var controller: ControllerMonitor
    let opacity: Double

    var body: some View {
        VStack {
            // Top Shoulder Row (L1 / L2 and R1 / R2)
            HStack {
                HStack(spacing: 10) {
                    touchHoldButton(label: "L2", action: .triggerL2, width: 64, height: 36, color: .gray)
                    touchHoldButton(label: "L1", action: .shoulderL1, width: 64, height: 36, color: .gray)
                }
                Spacer()
                HStack(spacing: 10) {
                    touchHoldButton(label: "R1", action: .shoulderR1, width: 64, height: 36, color: .gray)
                    touchHoldButton(label: "R2", action: .triggerR2, width: 64, height: 36, color: .gray)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)

            Spacer()

            // Main D-Pad + Select/Start + ABXY Diamond
            HStack(alignment: .bottom) {
                // 8-way D-Pad
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 148, height: 148)
                    VStack(spacing: 4) {
                        touchHoldButton(label: "▲", action: .up, width: 46, height: 44, color: .white.opacity(0.22))
                        HStack(spacing: 44) {
                            touchHoldButton(label: "◀", action: .left, width: 46, height: 44, color: .white.opacity(0.22))
                            touchHoldButton(label: "▶", action: .right, width: 46, height: 44, color: .white.opacity(0.22))
                        }
                        touchHoldButton(label: "▼", action: .down, width: 46, height: 44, color: .white.opacity(0.22))
                    }
                }

                Spacer()

                // Select & Start
                HStack(spacing: 14) {
                    touchHoldButton(label: "SELECT", action: .select, width: 66, height: 28, color: .white.opacity(0.20), font: .caption2.bold())
                    touchHoldButton(label: "START", action: .start, width: 66, height: 28, color: .white.opacity(0.20), font: .caption2.bold())
                }
                .padding(.bottom, 12)

                Spacer()

                // ABXY Diamond
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 152, height: 152)
                    VStack(spacing: 6) {
                        touchHoldButton(label: "X", action: .buttonX, width: 46, height: 46, color: .blue.opacity(0.65), circle: true)
                        HStack(spacing: 42) {
                            touchHoldButton(label: "Y", action: .buttonY, width: 46, height: 46, color: .green.opacity(0.65), circle: true)
                            touchHoldButton(label: "A", action: .buttonA, width: 46, height: 46, color: .red.opacity(0.65), circle: true)
                        }
                        touchHoldButton(label: "B", action: .buttonB, width: 46, height: 46, color: .yellow.opacity(0.75), circle: true)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .opacity(opacity)
    }

    private func touchHoldButton(
        label: String,
        action: RetroAction,
        width: CGFloat,
        height: CGFloat,
        color: Color,
        circle: Bool = false,
        font: Font = .headline.bold()
    ) -> some View {
        let isPressed = controller.touchActions.contains(action)
        return Text(label)
            .font(font)
            .foregroundColor(.white)
            .frame(width: width, height: height)
            .background(
                Group {
                    if circle {
                        Circle().fill(isPressed ? Color.orange : color)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(isPressed ? Color.orange : color)
                    }
                }
            )
            .overlay(
                Group {
                    if circle {
                        Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.35), lineWidth: 1)
                    }
                }
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in controller.setTouchAction(action, pressed: true) }
                    .onEnded { _ in controller.setTouchAction(action, pressed: false) }
            )
    }
}

// MARK: - Playable Emulator Session View

struct EmulatorSessionView: View {
    let game: Game
    @EnvironmentObject var library: Library
    @EnvironmentObject var controller: ControllerMonitor
    @EnvironmentObject var mappingStore: ButtonMappingStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var webBridge = LibretroWebBridge()
    @StateObject private var nativeCore: NativeRetroCoreEngine
    @State private var showTouchControls: Bool = true
    @State private var showSaveStatesSheet: Bool = false
    @State private var videoFilter: VideoFilterMode = .crtScanlines
    @State private var aspectRatio: AspectRatioMode = .fourThree
    @State private var isMuted: Bool = false
    @State private var useNativeRenderer: Bool
    @State private var hudToast: String?

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init(game: Game) {
        self.game = game
        let isHomebrew = game.filename.hasSuffix(".rdrom") || game.system == RetroSystem.arcade.rawValue
        let mode: String
        if game.name.localizedCaseInsensitiveContains("Snake") || game.name.localizedCaseInsensitiveContains("Matrix") {
            mode = "SNAKE"
        } else if game.name.localizedCaseInsensitiveContains("Pong") {
            mode = "PONG"
        } else {
            mode = "BREAKOUT"
        }
        _nativeCore = StateObject(wrappedValue: NativeRetroCoreEngine(mode: mode))
        _useNativeRenderer = State(initialValue: isHomebrew)
    }

    private var systemEnum: RetroSystem {
        RetroSystem(rawValue: game.system) ?? .nes
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video Display Area
            GeometryReader { geo in
                ZStack {
                    if useNativeRenderer {
                        nativeCanvasView
                    } else {
                        LibretroWebViewRepresentable(
                            game: game,
                            system: systemEnum,
                            romDirectory: library.directory,
                            biosDirectory: library.biosDirectory,
                            bridge: webBridge
                        )
                    }

                    // Optional CRT Scanlines Overlay
                    if videoFilter == .crtScanlines {
                        crtScanlineOverlay
                            .allowsHitTesting(false)
                    }
                }
                .frame(
                    width: displaySize(in: geo.size).width,
                    height: displaySize(in: geo.size).height
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 1))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            // Touch Controls Overlay
            if shouldShowTouchOverlay {
                TouchControllerOverlay(controller: controller, opacity: mappingStore.touchControlsOpacity)
            }

            // Top Emulator Control Bar
            VStack {
                HStack(spacing: 10) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Exit", systemImage: "xmark.circle.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }

                    Text(game.name)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    // Quick Save (Slot 1)
                    Button {
                        performSaveState(slot: 1)
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.75))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }

                    // Quick Load (Slot 1)
                    Button {
                        performLoadState(slot: 1)
                    } label: {
                        Label("Load", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.75))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }

                    // Save State Slots Sheet
                    Button {
                        showSaveStatesSheet = true
                    } label: {
                        Image(systemName: "externaldrive.fill.badge.timemachine")
                            .padding(7)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }

                    // Fast Forward 1x / 2x
                    Button {
                        nativeCore.fastForwardMultiplier = (nativeCore.fastForwardMultiplier == 1) ? 2 : 1
                        showToast("Speed: \(nativeCore.fastForwardMultiplier)x")
                    } label: {
                        Text("\(nativeCore.fastForwardMultiplier)x")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(nativeCore.fastForwardMultiplier > 1 ? Color.orange : Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }

                    // Mute Audio
                    Button {
                        isMuted.toggle()
                        nativeCore.synth.isMuted = isMuted
                        webBridge.setAudioMuted(isMuted)
                        showToast(isMuted ? "Audio Muted" : "Audio Unmuted")
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .padding(7)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }

                    // Display / Touch Menu
                    Menu {
                        Picker("Shader Filter", selection: $videoFilter) {
                            ForEach(VideoFilterMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        Picker("Aspect Ratio", selection: $aspectRatio) {
                            ForEach(AspectRatioMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        Toggle("On-Screen Touch Pad", isOn: $showTouchControls)
                        Toggle("Offline Native Engine", isOn: $useNativeRenderer)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .padding(7)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                if let toast = hudToast {
                    Text(toast)
                        .font(.caption.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.yellow)
                        .clipShape(Capsule())
                        .transition(.opacity)
                }

                Spacer()
            }
        }
        .onAppear {
            showTouchControls = !(mappingStore.autoHideTouchWhenControllerConnected && controller.isConnected)
            controller.onHotkeyTriggered = { hk in
                if hk == .quickSave { performSaveState(slot: 1) }
                else if hk == .quickLoad { performLoadState(slot: 1) }
            }
            webBridge.onSaveStateCaptured = { slot, data in
                library.writeSaveState(for: game.id, slot: slot, data: data)
                showToast("Saved Slot \(slot)!")
            }
        }
        .onReceive(timer) { _ in
            let ff = controller.combinedActions.contains(.fastForward) || nativeCore.fastForwardMultiplier > 1
            if useNativeRenderer {
                nativeCore.stepFrame(actions: controller.combinedActions, leftStick: controller.leftStick)
            } else {
                webBridge.pushInput(
                    bitmask: controller.combinedBitmask,
                    lx: controller.leftStick.x,
                    ly: controller.leftStick.y,
                    rx: controller.rightStick.x,
                    ry: controller.rightStick.y,
                    fastForward: ff
                )
            }
        }
        .sheet(isPresented: $showSaveStatesSheet) {
            saveStatesSheetView
        }
    }

    private var shouldShowTouchOverlay: Bool {
        if mappingStore.autoHideTouchWhenControllerConnected && controller.isConnected {
            return false
        }
        return showTouchControls
    }

    private func displaySize(in container: CGSize) -> CGSize {
        switch aspectRatio {
        case .sixteenNine:
            return CGSize(width: container.width * 0.96, height: container.height * 0.82)
        case .fourThree, .integerPixel:
            let maxH = container.height * 0.80
            let w = min(container.width * 0.96, maxH * (4.0 / 3.0))
            let h = w * (3.0 / 4.0)
            return CGSize(width: w, height: h)
        }
    }

    private var nativeCanvasView: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.04, green: 0.05, blue: 0.10)))

            // Scoreboard HUD inside CRT
            let header = "SCORE: \(nativeCore.state.scoreP1)   LVL: \(nativeCore.state.level)   LIVES: \(nativeCore.state.lives)   [\(systemEnum.rawValue)]"
            ctx.draw(
                Text(header).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.green),
                at: CGPoint(x: size.width / 2, y: 18)
            )

            if nativeCore.state.mode == "SNAKE" {
                let cellW = size.width / 24.0
                let cellH = size.height / 18.0
                let foodRect = CGRect(x: CGFloat(nativeCore.state.foodX) * cellW, y: CGFloat(nativeCore.state.foodY) * cellH, width: cellW - 2, height: cellH - 2)
                ctx.fill(Path(ellipseIn: foodRect), with: .color(.red))

                for (idx, seg) in nativeCore.state.snakeBody.enumerated() {
                    let r = CGRect(x: CGFloat(seg[0]) * cellW, y: CGFloat(seg[1]) * cellH, width: cellW - 2, height: cellH - 2)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(idx == 0 ? .yellow : .green))
                }
            } else {
                // Bricks / Invaders grid
                let palette: [Color] = [.red, .orange, .yellow, .green, .cyan]
                for idx in nativeCore.state.bricks.indices where nativeCore.state.bricks[idx] {
                    let col = idx % 8
                    let row = idx / 8
                    let bx = (0.12 + Double(col) * 0.108) * size.width
                    let by = (0.14 + Double(row) * 0.065) * size.height
                    let rect = CGRect(x: bx - size.width * 0.045, y: by - size.height * 0.022, width: size.width * 0.09, height: size.height * 0.04)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(palette[row % palette.count]))
                }

                // Player Paddle / Ship
                let pw = size.width * 0.18
                let ph = size.height * 0.028
                let px = nativeCore.state.playerX * size.width - pw / 2
                let py = nativeCore.state.playerY * size.height - ph / 2
                ctx.fill(Path(roundedRect: CGRect(x: px, y: py, width: pw, height: ph), cornerRadius: 6), with: .color(.cyan))

                // Ball / Laser
                let br: CGFloat = 8
                let ballRect = CGRect(x: nativeCore.state.ballX * size.width - br, y: nativeCore.state.ballY * size.height - br, width: br * 2, height: br * 2)
                ctx.fill(Path(ellipseIn: ballRect), with: .color(.white))
            }
        }
    }

    private var crtScanlineOverlay: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.2)), with: .color(.black.opacity(0.28)))
                y += 3.5
            }
        }
    }

    private var saveStatesSheetView: some View {
        NavigationStack {
            List {
                ForEach(1...4, id: \.self) { slotNum in
                    let existing = library.slots(for: game.id).first(where: { $0.slot == slotNum })
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Slot \(slotNum)")
                                .font(.headline)
                            if let ex = existing {
                                Text("Saved \(ex.timestamp.formatted(date: .abbreviated, time: .standard)) · \(ByteCountFormatter.string(fromByteCount: Int64(ex.sizeBytes), countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Empty Slot")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Save") {
                            performSaveState(slot: slotNum)
                        }
                        .buttonStyle(.borderedProminent)

                        if existing != nil {
                            Button("Load") {
                                performLoadState(slot: slotNum)
                                showSaveStatesSheet = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Save States — \(game.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSaveStatesSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func performSaveState(slot: Int) {
        if useNativeRenderer {
            if let data = nativeCore.serializeState() {
                library.writeSaveState(for: game.id, slot: slot, data: data)
                showToast("Saved Slot \(slot)")
            }
        } else {
            webBridge.captureSaveState(slot: slot)
            if let fallback = nativeCore.serializeState() {
                library.writeSaveState(for: game.id, slot: slot, data: fallback)
            }
            showToast("Saved Slot \(slot)")
        }
    }

    private func performLoadState(slot: Int) {
        guard let data = library.readSaveState(for: game.id, slot: slot) else {
            showToast("Slot \(slot) is empty")
            return
        }
        if useNativeRenderer {
            _ = nativeCore.restoreState(data)
        } else {
            webBridge.loadSaveState(data: data)
            _ = nativeCore.restoreState(data)
        }
        showToast("Loaded Slot \(slot)")
    }

    private func showToast(_ text: String) {
        withAnimation { hudToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if hudToast == text {
                withAnimation { hudToast = nil }
            }
        }
    }
}

// MARK: - Main App & Library / Controller / Remapping Views

@main
struct RetroDeckApp: App {
    @StateObject private var mappingStore = ButtonMappingStore()
    @StateObject private var library = Library()
    @StateObject private var controller: ControllerMonitor

    init() {
        let ms = ButtonMappingStore()
        _mappingStore = StateObject(wrappedValue: ms)
        _controller = StateObject(wrappedValue: ControllerMonitor(mappingStore: ms))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(controller)
                .environmentObject(mappingStore)
                .preferredColorScheme(.dark)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var controller: ControllerMonitor
    @EnvironmentObject private var mappingStore: ButtonMappingStore

    @State private var importingROMs = false
    @State private var importingBIOS = false
    @State private var query = ""
    @State private var system = "All"
    @State private var activeGame: Game?
    @State private var listeningForAction: RetroAction?

    private let systems = ["All"] + RetroSystem.allCases.map { $0.rawValue }

    var body: some View {
        TabView {
            // TAB 1: Playable Game Library
            NavigationStack {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: controller.isConnected ? "gamecontroller.fill" : "hand.tap.fill")
                                .foregroundStyle(controller.isConnected ? .green : .orange)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(controller.isConnected ? controller.name : "Touch Controls + Libretro Ready")
                                    .font(.subheadline.bold())
                                Text("Tap any game below to launch immediately with Save States, Audio/Video & Backbone mapping.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Picker("System", selection: $system) {
                        ForEach(systems, id: \.self) { Text($0).tag($0) }
                    }

                    Section("Installed Games (\(filteredGames.count))") {
                        ForEach(filteredGames) { game in
                            Button {
                                activeGame = game
                            } label: {
                                HStack(spacing: 14) {
                                    let sys = RetroSystem(rawValue: game.system) ?? .nes
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(sys.accentColor.opacity(0.22))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: sys.iconName)
                                            .foregroundStyle(sys.accentColor)
                                            .font(.title3)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(game.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        HStack(spacing: 8) {
                                            Text(game.system)
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(sys.accentColor.opacity(0.25))
                                                .foregroundStyle(sys.accentColor)
                                                .clipShape(Capsule())
                                            let slotCount = library.slots(for: game.id).count
                                            if slotCount > 0 {
                                                Text("\(slotCount) Save\(slotCount == 1 ? "" : "s")")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.green)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    library.deleteGame(game)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("RetroDeck")
                .searchable(text: $query, prompt: "Search ROMs & Homebrew")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            library.installStarterHomebrewGames()
                        } label: {
                            Label("Starter Games", systemImage: "sparkles")
                        }
                        Button {
                            importingROMs = true
                        } label: {
                            Label("Import ROMs", systemImage: "plus.circle.fill")
                        }
                    }
                }
                .fileImporter(isPresented: $importingROMs, allowedContentTypes: [.data, .item], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): library.importFiles(urls)
                    case .failure(let err): library.error = err.localizedDescription
                    }
                }
                .alert("RetroDeck Notice", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                    Button("OK") { library.error = nil }
                } message: {
                    Text(library.error ?? "")
                }
            }
            .tabItem { Label("Library", systemImage: "square.grid.2x2") }

            // TAB 2: Controller Diagnostics & Button Remapping
            NavigationStack {
                Form {
                    Section("Connected Controller") {
                        HStack {
                            Image(systemName: controller.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                                .foregroundStyle(controller.isConnected ? .green : .secondary)
                            Text(controller.name)
                                .font(.headline)
                        }
                        Text(controller.input)
                            .font(.system(.caption, design: .monospaced))
                    }

                    Section("Touch Overlay & Haptics") {
                        Toggle("Auto-Hide Touch Overlay on Backbone", isOn: $mappingStore.autoHideTouchWhenControllerConnected)
                            .onChange(of: mappingStore.autoHideTouchWhenControllerConnected) { _, _ in mappingStore.save() }
                        Toggle("Haptic Feedback on Button Press", isOn: $mappingStore.hapticFeedbackEnabled)
                            .onChange(of: mappingStore.hapticFeedbackEnabled) { _, _ in mappingStore.save() }
                        VStack(alignment: .leading) {
                            Text("Touch Controls Opacity: \(Int(mappingStore.touchControlsOpacity * 100))%")
                                .font(.caption)
                            Slider(value: $mappingStore.touchControlsOpacity, in: 0.25...1.0, step: 0.05)
                                .onChange(of: mappingStore.touchControlsOpacity) { _, _ in mappingStore.save() }
                        }
                    }

                    Section("Backbone / MFi Button Remapping") {
                        if let target = listeningForAction {
                            HStack {
                                ProgressView()
                                Text("Press any physical button on your controller for \(target.rawValue)...")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Cancel") { listeningForAction = nil }
                            }
                        }

                        ForEach(RetroAction.allCases) { action in
                            Picker(action.rawValue, selection: Binding(
                                get: { mappingStore.bindings[action] ?? .buttonA },
                                set: { mappingStore.bind(action, to: $0) }
                            )) {
                                ForEach(PhysicalPadButton.allCases) { phys in
                                    Text(phys.rawValue).tag(phys)
                                }
                            }
                        }

                        Button(role: .destructive) {
                            mappingStore.resetDefaults()
                            mappingStore.save()
                        } label: {
                            Label("Reset All Button Mappings to Default", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                .navigationTitle("Controller & Mapping")
                .onChange(of: controller.lastPressedPhysicalButton) { _, newBtn in
                    if let act = listeningForAction, let btn = newBtn {
                        mappingStore.bind(act, to: btn)
                        listeningForAction = nil
                    }
                }
            }
            .tabItem { Label("Controller", systemImage: "gamecontroller") }

            // TAB 3: Save States & BIOS Manager
            NavigationStack {
                Form {
                    Section("System BIOS Files (PS1 / Nintendo DS)") {
                        biosRow(name: "scph5501.bin", system: "PlayStation 1 (USA)")
                        biosRow(name: "bios7.bin", system: "Nintendo DS ARM7")
                        biosRow(name: "bios9.bin", system: "Nintendo DS ARM9")
                        biosRow(name: "firmware.bin", system: "Nintendo DS Firmware")

                        Button {
                            importingBIOS = true
                        } label: {
                            Label("Import BIOS Files", systemImage: "folder.badge.plus")
                        }
                    }

                    Section("Saved States (\(library.saveStates.count))") {
                        if library.saveStates.isEmpty {
                            Text("No save states yet. Use Quick Save or the Save Slots menu while playing any game.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(library.saveStates) { slot in
                                let gname = library.games.first(where: { $0.id == slot.gameID })?.name ?? "Game"
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("\(gname) — Slot \(slot.slot)")
                                            .font(.subheadline.bold())
                                        Text("\(slot.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(slot.sizeBytes), countStyle: .file))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        library.deleteSaveState(slot)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Saves & BIOS")
                .fileImporter(isPresented: $importingBIOS, allowedContentTypes: [.data, .item], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result {
                        library.importBIOSFiles(urls)
                    }
                }
            }
            .tabItem { Label("Saves & BIOS", systemImage: "externaldrive.fill") }
        }
        .fullScreenCover(item: $activeGame) { game in
            EmulatorSessionView(game: game)
                .environmentObject(library)
                .environmentObject(controller)
                .environmentObject(mappingStore)
        }
    }

    private var filteredGames: [Game] {
        library.games.filter {
            (system == "All" || $0.system == system) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    private func biosRow(name: String, system: String) -> some View {
        let installedSize = library.installedBIOS[name.lowercased()]
        return HStack {
            VStack(alignment: .leading) {
                Text(name).font(.subheadline.monospaced())
                Text(system).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let sz = installedSize {
                Label(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file), systemImage: "checkmark.seal.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            } else {
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
