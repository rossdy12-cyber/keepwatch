import SwiftUI
import LocalAuthentication

@main
struct AuthVaultApp: App {
    @StateObject private var vault = Vault()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var lock = LockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                VaultView()
                    .environmentObject(vault)
                    .environmentObject(settings)
                    .blur(radius: showLock ? 20 : 0)
                if showLock { LockScreen { lock.authenticate() } }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .onAppear { settings.lockEnabled ? lock.authenticate() : (lock.locked = false) }
            .onChange(of: scenePhase) { phase in
                guard settings.lockEnabled else { lock.locked = false; return }
                if phase == .active, lock.locked { lock.authenticate() }
                else if phase == .background { lock.locked = true }
            }
        }
    }

    private var showLock: Bool { settings.lockEnabled && lock.locked }
}

@MainActor
final class LockManager: ObservableObject {
    @Published var locked = true
    private var inFlight = false

    func authenticate() {
        guard !inFlight else { return }
        inFlight = true
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passcode"
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock AuthVault") { ok, _ in
                Task { @MainActor in self.locked = !ok; self.inFlight = false }
            }
        } else {
            locked = false   // no passcode/biometrics set up → don't lock the user out
            inFlight = false
        }
    }
}

struct LockScreen: View {
    let unlock: () -> Void
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill").font(.system(size: 54)).foregroundStyle(Theme.accent)
                Text("AuthVault").font(.title2.weight(.semibold))
                Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
            }
        }
    }
}
