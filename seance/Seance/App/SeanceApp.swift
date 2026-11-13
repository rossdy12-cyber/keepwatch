import SwiftUI

@main
struct SeanceApp: App {
    @UIApplicationDelegateAdaptor(MatrixAppDelegate.self) private var appDelegate
    @StateObject private var matrix = MatrixStore(keychainService: "app.keepwatch.seance")
    @Environment(\.scenePhase) private var phase

    init() {
        Theme.configureAppearance()
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = Theme.uiVoid
        let item = UITabBarItemAppearance()
        let font = UIFont(name: "Cinzel-Regular", size: 10) ?? .systemFont(ofSize: 10)
        let ash = UIColor(red: 0.62, green: 0.55, blue: 0.53, alpha: 1)
        item.normal.titleTextAttributes = [.font: font, .foregroundColor: ash]
        item.normal.iconColor = ash
        item.selected.titleTextAttributes = [.font: font, .foregroundColor: Theme.uiBlood]
        item.selected.iconColor = Theme.uiBlood
        tab.stackedLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if matrix.session == nil {
                    MatrixSignIn(appName: "Séance", tagline: "VOICES FROM BEYOND", deviceName: "Séance on iPhone")
                } else {
                    TabView {
                        ChatsView().tabItem { Label("Whispers", systemImage: "bubble.left.and.bubble.right") }
                            .badge(unreadCount)
                        SanctumView().tabItem { Label("Sanctum", systemImage: "gearshape") }
                    }
                    .onAppear { matrix.start() }
                }
            }
            .environmentObject(matrix)
            .onChange(of: matrix.initialSyncDone) { _, done in
                guard done else { return }
                MatrixPush.shared.matrix = matrix
                Task { await MatrixPush.shared.sync() }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.blood)
            .overlay(alignment: .top) {
                if let message = matrix.errorMessage {
                    Text(message)
                        .font(Theme.serif(14)).foregroundStyle(Theme.bone)
                        .padding(12).frame(maxWidth: .infinity)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
                        .padding(.horizontal).padding(.top, 50)
                        .onTapGesture { matrix.errorMessage = nil }
                        .task { try? await Task.sleep(nanoseconds: 5_000_000_000); matrix.errorMessage = nil }
                }
            }
        }
        .onChange(of: phase) { _, now in
            if now == .active, matrix.session != nil { matrix.resume() }
        }
    }

    private var unreadCount: Int {
        matrix.rooms.values.filter { $0.bridge?.protocolID == "whatsapp" && $0.unread > 0 }.count
    }
}
