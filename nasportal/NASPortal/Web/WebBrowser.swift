import SwiftUI
import WebKit

/// A web page to show: the TrueNAS web interface, or an app's own web UI.
struct WebDestination: Identifiable, Equatable {
    var title: String
    var url: URL
    var id: String { url.absoluteString }
}

/// Keeps one web view per site alive while the app runs, so leaving and coming back returns to
/// where you were. Every page shares the same cookie store, so one Authelia sign-in covers every app,
/// and sign-ins are kept between launches.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var views: [String: WKWebView] = [:]

    func webView(for url: URL) -> (view: WKWebView, isNew: Bool) {
        let key = url.absoluteString
        if let existing = views[key] { return (existing, false) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor(Theme.background)
        view.scrollView.backgroundColor = UIColor(Theme.background)
        view.scrollView.refreshControl = UIRefreshControl()
        views[key] = view
        return (view, true)
    }
}

/// Tracks a web view's loading state for the toolbar and handles certificates, pop-ups and dialogs.
@MainActor
final class WebPageModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var errorMessage: String?

    let destination: WebDestination
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    init(destination: WebDestination) {
        self.destination = destination
        let (view, isNew) = WebViewPool.shared.webView(for: destination.url)
        webView = view
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        if let refresh = view.scrollView.refreshControl {
            refresh.removeTarget(nil, action: nil, for: .valueChanged)
            refresh.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        }
        observations = [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.canGoBack
                Task { @MainActor in self?.canGoBack = value }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.canGoForward
                Task { @MainActor in self?.canGoForward = value }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.isLoading
                Task { @MainActor in
                    self?.isLoading = value
                    if !value { view.scrollView.refreshControl?.endRefreshing() }
                }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in self?.progress = value }
            }
        ]
        if isNew || view.url == nil {
            view.load(URLRequest(url: destination.url))
        }
    }

    @objc private func pulledToRefresh() {
        reload()
    }

    func goHome() {
        errorMessage = nil
        webView.load(URLRequest(url: destination.url))
    }

    func reload() {
        errorMessage = nil
        if webView.url == nil { goHome() } else { webView.reload() }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TrueNAS and many NAS apps use self-signed certificates on their Tailscale / home addresses.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           CertificatePolicy.allowsSelfSigned(host: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Phone numbers, e-mail and App Store links go to the system; everything else stays in the app.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.errorMessage = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in webView.reload() }
    }

    private nonisolated func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return } // frame load interrupted
        let message = Self.describe(nsError)
        Task { @MainActor in
            self.errorMessage = message
            self.webView.scrollView.refreshControl?.endRefreshing()
        }
    }

    private nonisolated static func describe(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        let code = " (error \(error.code))"
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return "The iPhone is offline." + code
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "That address couldn't be found. Check it in Settings." + code
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
            return "Couldn't reach the server. For a 100.x address, check that Tailscale is on." + code
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return "The server's certificate wasn't accepted. For a self-signed certificate on a home or Tailscale address, turn on \"Accept self-signed certificates\" in Settings." + code
        default:
            return error.localizedDescription + code
        }
    }

    // MARK: WKUIDelegate

    /// Links that open a new window (target="_blank") open in the same view instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            Self.present(message: message, buttons: [("OK", .default, { completionHandler() })])
        }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            Self.present(message: message, buttons: [("Cancel", .cancel, { completionHandler(false) }),
                                                     ("OK", .default, { completionHandler(true) })])
        }
    }

    private static func present(message: String, buttons: [(String, UIAlertAction.Style, () -> Void)]) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        for (title, style, action) in buttons {
            alert.addAction(UIAlertAction(title: title, style: style) { _ in action() })
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let top {
            top.present(alert, animated: true)
        } else {
            buttons.first?.2()
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(Theme.background)
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

/// A web page with back / forward / home / reload controls in the navigation bar.
struct WebScreen: View {
    let showsDone: Bool
    @StateObject private var page: WebPageModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(destination: WebDestination, showsDone: Bool) {
        self.showsDone = showsDone
        _page = StateObject(wrappedValue: WebPageModel(destination: destination))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebViewContainer(webView: page.webView)
                if page.isLoading && page.progress < 1 {
                    ProgressView(value: page.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                }
                if let error = page.errorMessage {
                    MessageCard(symbol: "wifi.exclamationmark", title: "Couldn't open \(page.destination.title)",
                                message: error, color: Theme.warning, actionTitle: "Try again") { page.reload() }
                        .padding(16)
                }
            }
            .navigationTitle(page.destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .portalChrome()
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    if showsDone {
                        Button("Done") { dismiss() }
                    }
                    Button { page.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!page.canGoBack)
                        .accessibilityLabel("Back")
                    Button { page.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!page.canGoForward)
                        .accessibilityLabel("Forward")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if page.isLoading {
                        Button { page.webView.stopLoading() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Stop")
                    } else {
                        Button { page.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload")
                    }
                    Menu {
                        Button { page.goHome() } label: { Label("Back to start page", systemImage: "house") }
                        Button {
                            openURL(page.webView.url ?? page.destination.url)
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                        Button {
                            UIPasteboard.general.url = page.webView.url ?? page.destination.url
                        } label: {
                            Label("Copy link", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}
