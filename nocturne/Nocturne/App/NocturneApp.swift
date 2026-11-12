import SwiftUI

enum Module: String, Identifiable, CaseIterable {
    case phone, messages, clock, weather, notes, calculator, music, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone: return "Phone"
        case .messages: return "Messages"
        case .clock: return "Chronometer"
        case .weather: return "Skies"
        case .notes: return "Grimoire"
        case .calculator: return "Reckoner"
        case .music: return "Requiem"
        case .settings: return "Altar"
        }
    }
    var symbol: String {
        switch self {
        case .phone: return "phone.fill"
        case .messages: return "envelope.fill"
        case .clock: return "clock.fill"
        case .weather: return "cloud.moon.fill"
        case .notes: return "book.closed.fill"
        case .calculator: return "function"
        case .music: return "music.note"
        case .settings: return "gearshape.fill"
        }
    }
}

@main
struct NocturneApp: App {
    @StateObject private var store = Store()
    @State private var route: Module?
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LauncherView(route: $route)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(store.theme.accentColor)
                .fullScreenCover(item: $route) { module in
                    ModuleHost(module: module)
                        .environmentObject(store)
                }
                .fullScreenCover(isPresented: $store.inCall) {
                    CallView().environmentObject(store)
                }
                .onOpenURL { url in handle(url) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { PushManager.shared.reregister() }
                }
        }
    }

    /// Routes nocturne:// deep links (e.g. from an ntfy push).
    private func handle(_ url: URL) {
        guard let host = url.host else { return }
        switch host {
        case "setup":
            // From a join link: nocturne://setup?server=…&token=… signs this person in.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let server = items.first(where: { $0.name == "server" })?.value, !server.isEmpty,
               let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty {
                store.relayURL = server
                store.relayToken = token
                Task { @MainActor in
                    if let me = await Account.fetchMe(store) { Account.apply(me, to: store) }
                    PushManager.shared.reregister()
                    route = .messages
                }
            }
        case "chat", "messages":
            // Optional room in the path (nocturne://chat/<room>) opens that conversation.
            let room = url.pathComponents.filter { $0 != "/" }.first
            if let room, !room.isEmpty { store.chatRoom = room; store.pendingRoom = room }
            route = .messages
        case "call":
            let room = url.pathComponents.filter { $0 != "/" }.first
            if let room, !room.isEmpty { store.chatRoom = room }
            store.inCall = true
        default:
            if let m = Module(rawValue: host) { route = m }
        }
    }
}

/// Wraps a module so it has a consistent gothic chrome and a dismiss control.
struct ModuleHost: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let module: Module

    var body: some View {
        ZStack {
            GothicBackground(theme: store.theme)
            content
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .padding(10)
                    .background(Circle().fill(store.theme.panelColor))
                    .overlay(Circle().strokeBorder(store.theme.accentColor.opacity(0.4)))
                    .foregroundStyle(store.theme.textColor)
            }
            .padding(.leading, 16).padding(.top, 8)
        }
    }

    @ViewBuilder private var content: some View {
        switch module {
        case .phone: PhoneView()
        case .messages: MessagesHome()
        case .clock: ClockView()
        case .weather: WeatherView()
        case .notes: NotesView()
        case .calculator: CalculatorView()
        case .music: MusicView()
        case .settings: SettingsView()
        }
    }
}
