import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var adblock = AdBlock.enabled

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Block ads & trackers", isOn: $adblock)
                        .tint(Crimson.accent)
                        .onChange(of: adblock) { _, on in
                            AdBlock.enabled = on
                            for tab in store.tabs {
                                AdBlock.apply(to: tab.webView.configuration.userContentController)
                                tab.webView.reload()
                            }
                        }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Blocks known ad, analytics and tracker hosts across every tab. Changes reload open tabs.")
                        .foregroundStyle(Crimson.muted)
                }.listRowBackground(Crimson.panel)

                Section("Data") {
                    Button(role: .destructive) { store.clearHistory() } label: {
                        Label("Clear history", systemImage: "trash")
                    }.tint(Crimson.accent2)
                }.listRowBackground(Crimson.panel)

                Section {
                    LabeledContent("Search engine", value: "DuckDuckGo")
                    LabeledContent("Engine", value: "WebKit")
                    LabeledContent("Version", value: "1.0.0")
                } header: {
                    Text("About")
                } footer: {
                    Text("Crimson — a private, gothic browser with built-in ad blocking and userscripts.")
                        .foregroundStyle(Crimson.muted)
                }
                .foregroundStyle(Crimson.text)
                .listRowBackground(Crimson.panel)
            }
            .scrollContentBackground(.hidden)
            .background(Crimson.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .tint(Crimson.accent)
    }
}
