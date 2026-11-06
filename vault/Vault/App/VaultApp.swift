import SwiftUI
import LocalAuthentication

@main
struct VaultApp: App {
    @StateObject private var auth = AuthModel()
    @StateObject private var vault = VaultModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isUnlocked {
                    LibraryView()
                } else {
                    LockView()
                }
            }
            .environmentObject(auth)
            .environmentObject(vault)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    auth.lock()
                }
            }
        }
    }
}

@MainActor
final class AuthModel: ObservableObject {
    @Published var isUnlocked = false
    @Published var errorMessage: String?

    func lock() {
        isUnlocked = false
    }

    func unlock() async {
        errorMessage = nil

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "Face ID is unavailable. Enable Face ID or set a device passcode."
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your private Vault."
            )

            if success {
                isUnlocked = true
            }
        } catch {
            if let authError = error as? LAError, authError.code == .userCancel {
                return
            }

            errorMessage = error.localizedDescription
        }
    }
}

struct LockView: View {
    @EnvironmentObject private var auth: AuthModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "faceid")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(.white)

            Text("Vault")
                .font(.largeTitle.bold())

            Text("Private photos and videos stored on your TrueNAS.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    await auth.unlock()
                }
            } label: {
                Label("Unlock", systemImage: "lock.open.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if let error = auth.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task {
            await auth.unlock()
        }
    }
}
