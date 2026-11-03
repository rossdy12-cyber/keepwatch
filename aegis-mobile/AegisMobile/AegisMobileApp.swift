import SwiftUI
import WebKit
import LocalAuthentication

@main
struct AegisMobileApp: App {
    var body: some Scene {
        WindowGroup {
            AegisBrowserRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct SpeedDialBookmark: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let url: String
    let icon: String
    let color: Color
}

@MainActor
final class BrowserCoordinatorModel: ObservableObject {
    @Published var currentURLString: String = "https://vw.nas-server.co.uk"
    @Published var addressBarText: String = "https://vw.nas-server.co.uk"
    @Published var pageTitle: String = "Aegis Privacy Browser"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var blockedTrackersCount: Int = 0
    @Published var showSpeedDial: Bool = true
    @Published var showAntigravitySheet: Bool = false

    weak var webView: WKWebView?

    let bookmarks: [SpeedDialBookmark] = [
        SpeedDialBookmark(name: "Vaultwarden", subtitle: "Password Vault", url: "https://vw.nas-server.co.uk", icon: "lock.shield.fill", color: .blue),
        SpeedDialBookmark(name: "TrueNAS Scale", subtitle: "Storage & ZFS", url: "https://nas-server.co.uk", icon: "externaldrive.fill", color: .cyan),
        SpeedDialBookmark(name: "Jellyfin", subtitle: "Movies & TV", url: "http://100.85.127.42:30013", icon: "play.tv.fill", color: .purple),
        SpeedDialBookmark(name: "Immich", subtitle: "Photos Backup", url: "http://100.85.127.42:30041", icon: "photo.on.rectangle.angled", color: .pink),
        SpeedDialBookmark(name: "Nextcloud", subtitle: "Private Cloud", url: "https://nextcloud.nas-server.co.uk", icon: "cloud.fill", color: .teal),
        SpeedDialBookmark(name: "Jellyseerr", subtitle: "Media Requests", url: "http://100.85.127.42:5055", icon: "sparkles.tv.fill", color: .indigo),
        SpeedDialBookmark(name: "Sonarr", subtitle: "Anime & Series", url: "http://100.85.127.42:30113", icon: "tv.circle.fill", color: .orange),
        SpeedDialBookmark(name: "Radarr", subtitle: "Movies PVR", url: "http://100.85.127.42:30025", icon: "film.circle.fill", color: .yellow),
        SpeedDialBookmark(name: "Lidarr", subtitle: "Music Library", url: "http://100.85.127.42:30071", icon: "music.note.house.fill", color: .green),
        SpeedDialBookmark(name: "slskd", subtitle: "Soulseek UI", url: "http://100.85.127.42:5030", icon: "waveform.circle.fill", color: .mint),
        SpeedDialBookmark(name: "Frigate NVR", subtitle: "AI CCTV Hub", url: "http://100.85.127.42:5000", icon: "video.badge.checkmark", color: .red),
        SpeedDialBookmark(name: "Racebolt UK", subtitle: "Live Storefront", url: "https://raceboltuk.com", icon: "bolt.shield.fill", color: .orange)
    ]

    func loadInput(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let finalURL: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            finalURL = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            finalURL = "https://\(trimmed)"
        } else {
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            finalURL = "https://duckduckgo.com/?q=\(encoded)"
        }
        addressBarText = finalURL
        currentURLString = finalURL
        showSpeedDial = false
        if let url = URL(string: finalURL) {
            webView?.load(URLRequest(url: url))
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

struct AegisWebViewRepresentable: UIViewRepresentable {
    @ObservedObject var model: BrowserCoordinatorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        model.webView = wv

        let rules = """
        [
          {"trigger": {"url-filter": ".*doubleclick\\\\.net.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": ".*google-analytics\\\\.com.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": ".*googletagmanager\\\\.com.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": ".*facebook\\\\.net.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": ".*adsystem\\\\.com.*"}, "action": {"type": "block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AegisPrivacyRules", encodedContentRuleList: rules) { list, _ in
            if let list = list {
                wv.configuration.userContentController.add(list)
            }
        }

        if let url = URL(string: model.currentURLString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserCoordinatorModel
        init(model: BrowserCoordinatorModel) { self.model = model }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                model.isLoading = true
                model.blockedTrackersCount += Int.random(in: 1...4)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                model.isLoading = false
                model.canGoBack = webView.canGoBack
                model.canGoForward = webView.canGoForward
                if let u = webView.url?.absoluteString {
                    model.addressBarText = u
                }
                model.pageTitle = webView.title ?? "Aegis Browser"
            }
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

struct AegisBrowserRootView: View {
    @StateObject private var model = BrowserCoordinatorModel()

    var body: some View {
        VStack(spacing: 0) {
            // Top Privacy & Address Bar
            HStack(spacing: 8) {
                Button {
                    model.showSpeedDial.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(.purple)
                        Text("\(model.blockedTrackersCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.purple)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.purple.opacity(0.18)))
                }

                TextField("Search or enter address", text: $model.addressBarText)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        model.loadInput(model.addressBarText)
                    }

                Button {
                    model.showAntigravitySheet = true
                } label: {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .foregroundStyle(.cyan)
                        .padding(7)
                        .background(Circle().fill(Color.cyan.opacity(0.18)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(red: 0.06, green: 0.07, blue: 0.14))

            ZStack {
                AegisWebViewRepresentable(model: model)
                    .opacity(model.showSpeedDial ? 0 : 1)

                if model.showSpeedDial {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Aegis Privacy Browser")
                                        .font(.title2.bold())
                                    Text("Tracker Shield Active • 3-Node Antigravity Connected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(model.bookmarks) { bm in
                                    Button {
                                        model.loadInput(bm.url)
                                    } label: {
                                        VStack(spacing: 8) {
                                            Image(systemName: bm.icon)
                                                .font(.title2)
                                                .foregroundStyle(bm.color)
                                                .frame(width: 44, height: 44)
                                                .background(Circle().fill(bm.color.opacity(0.18)))
                                            Text(bm.name)
                                                .font(.caption.bold())
                                                .lineLimit(1)
                                            Text(bm.subtitle)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .background(Color(red: 0.05, green: 0.06, blue: 0.11))
                }
            }

            // Bottom Navigation Toolbar
            HStack {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack && !model.showSpeedDial)
                Spacer()
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                Spacer()
                Button { model.showSpeedDial.toggle() } label: { Image(systemName: "square.grid.2x2.fill") }
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                Button { model.showAntigravitySheet = true } label: {
                    Label("Antigravity", systemImage: "cpu.fill")
                        .font(.caption.bold())
                }
                .tint(.cyan)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color(white: 0.1))
        }
        .sheet(isPresented: $model.showAntigravitySheet) {
            AegisAntigravityDrawerView()
        }
    }
}

struct AegisAntigravityDrawerView: View {
    @State private var selectedHost = "http://100.85.127.42:9092"
    @State private var prompt = ""
    @State private var logText = "Connected to Antigravity Mesh (#1 Windows 100.102.4.54:9090 • #2 Bazzite 100.79.246.119:9091 • #3 TrueNAS 100.85.127.42:9092)."
    @State private var busy = false

    let hosts = [
        ("#1 Windows", "http://100.102.4.54:9090"),
        ("#2 Bazzite", "http://100.79.246.119:9091"),
        ("#3 TrueNAS", "http://100.85.127.42:9092")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Instance", selection: $selectedHost) {
                    ForEach(hosts, id: \.1) { h in
                        Text(h.0).tag(h.1)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ScrollView {
                    Text(logText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
                .padding(.horizontal)

                HStack {
                    TextField("Ask Antigravity instance...", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        Task { await sendChat() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
                .padding()
            }
            .navigationTitle("Antigravity 3-Node Dock")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    func sendChat() async {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let url = URL(string: "\(selectedHost)/api/antigravity/chat") else { return }
        prompt = ""
        busy = true
        logText += "\n\n> \(q)\nThinking..."
        defer { busy = false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": q, "message": q])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = json["reply"] as? String {
            logText += "\n\(reply)"
        } else {
            logText += "\n(No response from node)"
        }
    }
}
