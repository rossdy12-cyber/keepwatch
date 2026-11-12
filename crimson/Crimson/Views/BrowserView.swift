import SwiftUI

enum Panel: String, Identifiable { case bookmarks, history, scripts, settings; var id: String { rawValue } }

struct BrowserView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var showTabs = false
    @State private var panel: Panel?

    var body: some View {
        ZStack {
            Crimson.bg.ignoresSafeArea()
            if let tab = store.current {
                BrowserChrome(tab: tab, showTabs: $showTabs, panel: $panel)
            } else {
                ProgressView().tint(Crimson.accent)
            }
        }
        .task {
            await AdBlock.compileAsync()
            if store.tabs.isEmpty { store.newTab() }
        }
        .sheet(isPresented: $showTabs) { TabSwitcher(showTabs: $showTabs).environmentObject(store) }
        .sheet(item: $panel) { p in
            switch p {
            case .bookmarks: BookmarksView().environmentObject(store)
            case .history: HistoryView().environmentObject(store)
            case .scripts: UserScriptsView()
            case .settings: SettingsView().environmentObject(store)
            }
        }
    }
}

struct BrowserChrome: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var store: BrowserStore
    @Binding var showTabs: Bool
    @Binding var panel: Panel?

    @State private var address = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                WebContainer(tab: tab).id(tab.id)
                if tab.isLoading {
                    GeometryReader { geo in
                        Rectangle().fill(Crimson.accent)
                            .frame(width: geo.size.width * tab.progress, height: 2)
                    }
                    .frame(height: 2)
                }
            }
            bottomBar
        }
    }

    // MARK: address bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            if tab.isPrivate { Image(systemName: "eyeglasses").foregroundStyle(Crimson.accent2) }
            if editing {
                TextField("Search or enter address", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.webSearch).submitLabel(.go)
                    .focused($focused)
                    .foregroundStyle(Crimson.text)
                    .onSubmit { tab.load(address); editing = false; focused = false }
            } else {
                Text(displayURL)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(tab.urlString.isEmpty ? Crimson.muted : Crimson.text)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit() }
            }
            Button {
                if editing { editing = false; focused = false } else { tab.reloadOrStop() }
            } label: {
                Image(systemName: editing ? "xmark" : (tab.isLoading ? "xmark" : "arrow.clockwise"))
                    .foregroundStyle(Crimson.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Capsule().fill(Crimson.field))
        .overlay(Capsule().strokeBorder(Crimson.accent.opacity(0.25)))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
    }

    private var displayURL: String {
        guard let u = URL(string: tab.urlString), let host = u.host else {
            return tab.urlString.isEmpty ? "Search or enter address" : tab.urlString
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private func beginEdit() {
        address = tab.urlString
        editing = true
        focused = true
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            navButton("chevron.left", enabled: tab.canGoBack) { tab.goBack() }
            navButton("chevron.right", enabled: tab.canGoForward) { tab.goForward() }
            Spacer()
            navButton("book") { tab.reader() }
            Spacer()
            Button { showTabs = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Crimson.text, lineWidth: 1.8).frame(width: 22, height: 22)
                    Text("\(store.tabs.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Crimson.text)
                }
            }
            Spacer()
            menu
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(Crimson.panel.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Crimson.hairline), alignment: .top)
    }

    private func navButton(_ icon: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(enabled ? Crimson.text : Crimson.muted.opacity(0.4))
        }
        .disabled(!enabled)
    }

    private var menu: some View {
        Menu {
            Button { store.newTab() } label: { Label("New Tab", systemImage: "plus.square") }
            Button { store.newTab(isPrivate: true) } label: { Label("New Private Tab", systemImage: "eyeglasses") }
            Divider()
            Button { store.toggleBookmark(title: tab.title, url: tab.urlString) } label: {
                Label(store.isBookmarked(tab.urlString) ? "Remove Bookmark" : "Add Bookmark",
                      systemImage: store.isBookmarked(tab.urlString) ? "bookmark.fill" : "bookmark")
            }
            Button { panel = .bookmarks } label: { Label("Bookmarks", systemImage: "book.closed") }
            Button { panel = .history } label: { Label("History", systemImage: "clock") }
            Divider()
            Button { tab.toggleDark() } label: { Label(tab.darkMode ? "Light Page" : "Dark Page", systemImage: "moon.circle") }
            Button { tab.reader() } label: { Label("Reader Mode", systemImage: "doc.plaintext") }
            Button { panel = .scripts } label: { Label("Userscripts", systemImage: "curlybraces") }
            Divider()
            Button { panel = .settings } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(Crimson.text)
        }
    }
}
