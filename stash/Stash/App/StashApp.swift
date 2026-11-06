import SwiftUI

@main
struct StashApp: App {
    @StateObject private var store = StashStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView {
                    StashWebScreen()
                        .tabItem {
                            Label("Stash Web", systemImage: "play.rectangle.on.rectangle.fill")
                        }

                    NativeLibraryView()
                        .tabItem {
                            Label("Native Player", systemImage: "square.grid.2x2.fill")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                }
                .tint(StashTheme.accent)
                .environmentObject(store)

                if !store.isUnlocked {
                    LockOverlayView()
                        .environmentObject(store)
                        .transition(.opacity)
                } else if store.privacyBlur && scenePhase != .active {
                    PrivacyBlurOverlay()
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                if !store.isUnlocked {
                    store.unlockWithBiometrics()
                }
                await store.fetchStats()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    store.lockIfNeeded()
                } else if newPhase == .active && !store.isUnlocked {
                    store.unlockWithBiometrics()
                }
            }
        }
    }
}

private struct LockOverlayView: View {
    @EnvironmentObject private var store: StashStore

    var body: some View {
        ZStack {
            StashTheme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(StashTheme.accent)
                Text("Stash Locked")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(StashTheme.textPrimary)
                Text("Authenticate with Face ID or Passcode to continue.")
                    .font(.subheadline)
                    .foregroundStyle(StashTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    store.unlockWithBiometrics()
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(StashTheme.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
                .padding(.top, 8)
            }
            .padding(32)
        }
    }
}

private struct PrivacyBlurOverlay: View {
    var body: some View {
        ZStack {
            StashTheme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(StashTheme.accent)
                Text("STASH")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(StashTheme.textPrimary)
            }
        }
    }
}
