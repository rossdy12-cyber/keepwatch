import SwiftUI
import UniformTypeIdentifiers
import GameController
import Combine

struct Game: Identifiable, Codable {
    var id: UUID
    var name: String
    var system: String
    var filename: String
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var error: String?
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var writable = true
    private var index: URL { directory.appendingPathComponent("library.json") }

    init() {
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        do { games = try JSONDecoder().decode([Game].self, from: Data(contentsOf: index)) }
        catch { writable = false; self.error = "Library could not load; original files preserved. \(error.localizedDescription)" }
    }

    func importFiles(_ urls: [URL]) {
        guard writable else { return }
        let systems = ["nes": "NES", "sfc": "SNES", "smc": "SNES", "md": "Mega Drive", "gen": "Mega Drive", "z64": "N64", "n64": "N64", "v64": "N64", "nds": "Nintendo DS", "chd": "PS1"]
        for url in urls {
            guard let system = systems[url.pathExtension.lowercased()] else {
                error = "Unsupported format: \(url.lastPathComponent). Use uncompressed ROMs; PS1 currently accepts CHD only."
                continue
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let filename = id.uuidString + "." + url.pathExtension.lowercased()
            let target = directory.appendingPathComponent(filename)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                let game = Game(id: id, name: url.deletingPathExtension().lastPathComponent, system: system, filename: filename)
                let candidate = games + [game]
                do { try JSONEncoder().encode(candidate).write(to: index, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: target); throw error }
                games = candidate
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
final class ControllerMonitor: ObservableObject {
    @Published var name = "No controller connected"
    @Published var input = "Connect your Backbone and press a button."
    private var controller: GCController?
    private var tokens: [NSObjectProtocol] = []

    init() {
        for event in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            tokens.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    private func refresh() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        name = controller?.vendorName ?? (controller == nil ? "No controller connected" : "Game controller")
        controller?.extendedGamepad?.valueChangedHandler = { [weak self] pad, element in
            let buttons: [(String, GCControllerButtonInput)] = [("A", pad.buttonA), ("B", pad.buttonB), ("X", pad.buttonX), ("Y", pad.buttonY), ("L1", pad.leftShoulder), ("R1", pad.rightShoulder), ("L2", pad.leftTrigger), ("R2", pad.rightTrigger), ("Menu", pad.buttonMenu)]
            let pressed = buttons.filter { $0.1.isPressed }.map { $0.0 }.joined(separator: " ")
            let text = "Buttons: \(pressed.isEmpty ? "none" : pressed)\nD-pad: \(pad.dpad.xAxis.value), \(pad.dpad.yAxis.value)\nLeft stick: \(pad.leftThumbstick.xAxis.value), \(pad.leftThumbstick.yAxis.value)\nRight stick: \(pad.rightThumbstick.xAxis.value), \(pad.rightThumbstick.yAxis.value)"
            Task { @MainActor in self?.input = text }
        }
    }
}

@main
struct RetroDeckApp: App {
    @StateObject private var library = Library()
    @StateObject private var controller = ControllerMonitor()
    var body: some Scene {
        WindowGroup { LibraryView().environmentObject(library).environmentObject(controller).preferredColorScheme(.dark) }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var controller: ControllerMonitor
    @State private var importing = false
    @State private var query = ""
    @State private var system = "All"
    private let systems = ["All", "NES", "SNES", "Mega Drive", "N64", "Nintendo DS", "PS1"]

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section { Text("Preview build: emulator cores are not integrated. Games cannot be played yet.").foregroundStyle(.orange) }
                    Picker("System", selection: $system) { ForEach(systems, id: \.self) { Text($0).tag($0) } }
                    ForEach(library.games.filter { (system == "All" || $0.system == system) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { game in
                        NavigationLink {
                            VStack(spacing: 20) {
                                Image(systemName: "gamecontroller").font(.largeTitle)
                                Text(game.name).font(.title)
                                Text(game.system)
                                Text("Gameplay, save states and remapping are unavailable until the emulator core is integrated.").foregroundStyle(.secondary)
                            }.padding().navigationTitle("Game details")
                        } label: { VStack(alignment: .leading) { Text(game.name); Text(game.system).font(.caption).foregroundStyle(.secondary) } }
                    }
                    if library.games.isEmpty { Text("Import your own ROM files to create a library.") }
                }
                .navigationTitle("RetroDeck")
                .searchable(text: $query)
                .toolbar { Button("Import ROMs") { importing = true } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): library.importFiles(urls)
                    case .failure(let error): library.error = error.localizedDescription
                    }
                }
                .alert("Library notice", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                    Button("OK") { library.error = nil }
                } message: { Text(library.error ?? "") }
            }.tabItem { Label("Library", systemImage: "square.grid.2x2") }
            NavigationStack {
                Form {
                    Section("Connected controller") { Text(controller.name) }
                    Section("Live input test") { Text(controller.input).font(.system(.body, design: .monospaced)) }
                    Section("Status") { Text("USB-C Backbone input is read through Game Controller. Mapping to emulator cores is not implemented.") }
                }.navigationTitle("Controller")
            }.tabItem { Label("Controller", systemImage: "gamecontroller") }
            NavigationStack {
                Form {
                    Text("RetroDeck 0.1 — library and controller preview")
                    Text("No emulator cores, ROMs or BIOS files are bundled. No PS2 support.")
                    Text("Import formats: NES .nes; SNES .sfc/.smc; Mega Drive .md/.gen; N64 .z64/.n64/.v64; DS .nds; PS1 .chd. File extensions identify systems; import does not validate playable content.")
                    Text("ZIP archives and PS1 multi-file BIN/CUE sets are not supported in this preview.")
                }.navigationTitle("About")
            }.tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}
