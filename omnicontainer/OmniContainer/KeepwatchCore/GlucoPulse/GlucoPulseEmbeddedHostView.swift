import SwiftUI

struct GlucoPulseEmbeddedHostView: View {
    @ObservedObject private var store = GlucoStore.shared

    var body: some View {
        TabView {
            GlucoDashboardView()
                .tabItem {
                    Label("Glucose", systemImage: "waveform.path.ecg")
                }

            GlucoPumpHistoryView()
                .tabItem {
                    Label("Pump & BLE", systemImage: "drop.transmission")
                }

            GlucoSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
        }
        .environmentObject(store)
        .tint(GlucoTheme.tandemCyan)
        .preferredColorScheme(.dark)
        .onAppear {
            if store.g7DirectBLEEnabled {
                store.startDirectG7BLE()
                store.pollConnectedG7Peripherals()
            }
        }
    }
}
