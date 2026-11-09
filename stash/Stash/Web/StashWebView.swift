import SwiftUI
import WebKit

@MainActor
final class StashWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var lastLoadedBase: String = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor(StashTheme.background)
        view.scrollView.backgroundColor = UIColor(StashTheme.background)
        view.scrollView.refreshControl = UIRefreshControl()
        self.webView = view
        super.init()

        view.navigationDelegate = self
        view.uiDelegate = self
        view.scrollView.refreshControl?.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)

        observations = [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in
                let val = v.canGoBack
                Task { @MainActor in self?.canGoBack = val }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in
                let val = v.canGoForward
                Task { @MainActor in self?.canGoForward = val }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in
                let val = v.isLoading
                Task { @MainActor in
                    self?.isLoading = val
                    if !val { v.scrollView.refreshControl?.endRefreshing() }
                }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] v, _ in
                let val = v.estimatedProgress
                Task { @MainActor in self?.progress = val }
            }
        ]
    }

    func ensureLoaded(baseURL: URL?) {
        guard let url = baseURL else {
            errorMessage = "Invalid Stash server URL. Check the Settings tab."
            return
        }
        if lastLoadedBase != url.absoluteString || webView.url == nil {
            lastLoadedBase = url.absoluteString
            errorMessage = nil
            webView.load(URLRequest(url: url))
        }
    }

    func navigate(to url: URL?) {
        guard let url else { return }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    @objc private func pulledToRefresh() {
        reload()
    }

    func reload() {
        errorMessage = nil
        if webView.url == nil, let url = URL(string: lastLoadedBase) {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func showToast(_ text: String) {
        toastMessage = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self.toastMessage == text {
                self.toastMessage = nil
            }
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           StashCertPolicy.acceptSelfSigned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.errorMessage = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleError(error)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleError(error)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in webView.reload() }
    }

    private nonisolated func handleError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        let msg = nsError.localizedDescription
        Task { @MainActor in
            self.errorMessage = "\(msg)\n\nMake sure Tailscale is connected on your iPhone (or switch to TrueNAS Direct IP in Settings)."
            self.webView.scrollView.refreshControl?.endRefreshing()
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

private struct StashWKContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(StashTheme.background)
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

struct StashWebScreen: View {
    @EnvironmentObject private var store: StashStore
    @StateObject private var model = StashWebModel()
    @State private var fullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            if !fullScreen {
                topBar
                sectionStrip
            }

            ZStack(alignment: .top) {
                StashWKContainer(webView: model.webView)
                    .ignoresSafeArea(edges: fullScreen ? .all : [])

                if model.isLoading && model.progress < 1.0 {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(StashTheme.accent)
                }

                if let error = model.errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(StashTheme.warning)
                        Text("Couldn't Reach Stash")
                            .font(.headline)
                            .foregroundStyle(StashTheme.textPrimary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(StashTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button {
                                model.reload()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(StashTheme.accent, in: Capsule())
                                    .foregroundStyle(.black)
                            }
                            Button {
                                if store.serverAddress.contains("100.85.127.42") {
                                    store.serverAddress = "http://100.85.127.42:9999"
                                } else {
                                    store.serverAddress = "http://100.85.127.42:9999"
                                }
                                model.ensureLoaded(baseURL: store.baseURL)
                            } label: {
                                Label("Switch IP", systemImage: "network")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(StashTheme.card, in: Capsule())
                                    .foregroundStyle(StashTheme.textPrimary)
                            }
                        }
                    }
                    .padding(22)
                    .background(StashTheme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(StashTheme.border, lineWidth: 1))
                    .padding(20)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if fullScreen {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { fullScreen = false }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.65), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toastMessage {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(StashTheme.accent, in: Capsule())
                        .shadow(radius: 8)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(StashTheme.background)
        .onAppear {
            model.ensureLoaded(baseURL: store.baseURL)
        }
        .onChange(of: store.serverAddress) { _ in
            model.ensureLoaded(baseURL: store.baseURL)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.isOnline ? StashTheme.success : StashTheme.accent)
                    .frame(width: 8, height: 8)
                Text("STASH")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(StashTheme.textPrimary)
            }

            Spacer()

            Button { model.webView.goBack() } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 30, height: 30)
            }
            .disabled(!model.canGoBack)

            Button { model.webView.goForward() } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 30, height: 30)
            }
            .disabled(!model.canGoForward)

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
            }

            Menu {
                Button {
                    Task {
                        let msg = await store.triggerScan()
                        model.showToast(msg)
                    }
                } label: {
                    Label("Scan /data/IDrive-Sync", systemImage: "folder.badge.gearshape")
                }

                Button {
                    Task {
                        let msg = await store.triggerGenerate()
                        model.showToast(msg)
                    }
                } label: {
                    Label("Generate Previews & Covers", systemImage: "wand.and.stars")
                }

                Divider()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { fullScreen = true }
                } label: {
                    Label("Full-Screen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button {
                    UIPasteboard.general.url = model.webView.url ?? store.baseURL
                    model.showToast("Copied link")
                } label: {
                    Label("Copy Current Link", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 19))
                    .frame(width: 30, height: 30)
            }
        }
        .foregroundStyle(StashTheme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(StashTheme.card)
    }

    private var sectionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StashSection.allCases) { section in
                    let isSelected = store.activeSection == section
                    Button {
                        store.activeSection = section
                        model.navigate(to: store.url(for: section))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 12, weight: .semibold))
                            Text(section.label)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isSelected ? StashTheme.accent : StashTheme.card, in: Capsule())
                        .foregroundStyle(isSelected ? .black : StashTheme.textPrimary)
                        .overlay(Capsule().stroke(StashTheme.border, lineWidth: isSelected ? 0 : 1))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(StashTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StashTheme.border).frame(height: 1)
        }
    }
}
