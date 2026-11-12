import SwiftUI

struct TabSwitcher: View {
    @EnvironmentObject var store: BrowserStore
    @Binding var showTabs: Bool

    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(store.tabs) { tab in
                        TabCard(tab: tab, isCurrent: tab.id == store.currentID) {
                            store.select(tab); showTabs = false
                        } close: {
                            store.close(tab)
                        }
                    }
                }
                .padding(16)
            }
            .background(Crimson.bg.ignoresSafeArea())
            .navigationTitle("\(store.tabs.count) Tab\(store.tabs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { store.closeAll(); showTabs = false } label: {
                        Text("Close All")
                    }.tint(Crimson.accent2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.newTab(); showTabs = false } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { store.newTab(isPrivate: true); showTabs = false } label: {
                        Label("New Private Tab", systemImage: "eyeglasses")
                    }.tint(Crimson.accent2)
                }
            }
        }
        .tint(Crimson.accent)
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isCurrent: Bool
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if tab.isPrivate { Image(systemName: "eyeglasses").font(.caption2).foregroundStyle(Crimson.accent2) }
                    Text(tab.title).font(.caption).fontWeight(.medium).lineLimit(1).foregroundStyle(Crimson.text)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.caption2).foregroundStyle(Crimson.muted) }
                }
                .padding(10)
                Rectangle().fill(Crimson.hairline).frame(height: 0.5)
                Spacer(minLength: 0)
                Text(host).font(.caption2).foregroundStyle(Crimson.muted).lineLimit(1).padding(10)
            }
            .frame(height: 110, alignment: .top)
            .background(Crimson.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Crimson.accent : Crimson.hairline, lineWidth: isCurrent ? 2 : 0.5))
        }
        .buttonStyle(.plain)
    }

    private var host: String {
        URL(string: tab.urlString)?.host?.replacingOccurrences(of: "www.", with: "") ?? tab.urlString
    }
}
