import SwiftUI

@main
struct GlucoPulseApp: App {
    @StateObject private var store = GlucoStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "waveform.path.ecg.rectangle.fill")
                    }

                PumpHistoryView()
                    .tabItem {
                        Label("t:slim X2 & BLE", systemImage: "drop.transmission")
                    }

                SettingsView()
                    .tabItem {
                        Label("Sources", systemImage: "gearshape.fill")
                    }
            }
            .tint(GlucoTheme.tandemCyan)
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .task {
                await store.refreshAll()
            }
        }
    }
}
