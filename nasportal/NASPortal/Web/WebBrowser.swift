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
    private var messageProxies: [ObjectIdentifier: ScriptMessageProxy] = [:]

    func webView(for url: URL) -> (view: WKWebView, isNew: Bool) {
        let key = url.absoluteString
        if let existing = views[key] { return (existing, false) }
        let configuration = WKWebViewConfiguration()
        let proxy = ScriptMessageProxy()
        configuration.userContentController.addUserScript(
            WKUserScript(source: OTPScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(proxy, name: OTPScript.messageName)
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
        messageProxies[ObjectIdentifier(view)] = proxy
        return (view, true)
    }

    func messageProxy(for view: WKWebView) -> ScriptMessageProxy? {
        messageProxies[ObjectIdentifier(view)]
    }
}

/// Passes messages from the page to whichever screen currently shows the web view, without
/// the web view keeping that screen alive.
@MainActor
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebPageModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.codeFieldChanged(message.body as? String ?? "")
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
    @Published var host: String?
    /// True while the page shows a sign-in code field; the code button only appears then.
    @Published var codeFieldShown = false
    /// Briefly shown after a code was typed in for you.
    @Published var filledNotice: String?

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
        WebViewPool.shared.messageProxy(for: view)?.target = self
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
            },
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.url?.host
                Task { @MainActor in self?.host = value }
            }
        ]
        if isNew || view.url == nil {
            view.load(URLRequest(url: destination.url))
        }
    }

    // MARK: Two-factor codes

    /// A sign-in code field appeared ('empty' / 'filled') or went away ('gone').
    func codeFieldChanged(_ state: String) {
        codeFieldShown = state != "gone"
        if state == "empty" && OTPVault.shared.autoFill {
            fillOTP(force: false)
        }
    }

    /// Types the current code into the page's one-time-code field. Returns false when there's no code for this site.
    @discardableResult
    func fillOTP(force: Bool) -> Bool {
        guard let account = OTPVault.shared.account(for: webView.url?.host),
              let code = account.code() else { return false }
        let script = "window.__portalFillOTP && window.__portalFillOTP('\(code)', \(force ? "true" : "false"))"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let outcome = result as? String, outcome != "none", outcome != "already" else { return }
            Task { @MainActor in
                self.filledNotice = "\(account.name) code filled in"
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.filledNotice = nil
            }
        }
        return true
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
        Task { @MainActor in
            self.errorMessage = nil
            self.codeFieldShown = false
        }
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
            .overlay(alignment: .bottom) {
                OTPPill(page: page)
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

/// A small "2FA code" button at the bottom of sign-in pages for sites you've added a code for.
/// Tap to type the current code into the page; long-press to copy it.
private struct OTPPill: View {
    @ObservedObject var page: WebPageModel
    @ObservedObject private var vault = OTPVault.shared

    var body: some View {
        if page.codeFieldShown, let account = vault.account(for: page.host) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    page.fillOTP(force: true)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.filledNotice == nil ? "key.fill" : "checkmark.circle.fill")
                        if let notice = page.filledNotice {
                            Text(notice)
                        } else {
                            Text(OTPCodeLabel.format(account.code(at: context.date) ?? "------"))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                            Text("\(account.secondsLeft(at: context.date))s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.background.opacity(0.7))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = account.code()
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }
                }
                .accessibilityLabel("Fill in the \(account.name) two-factor code")
            }
            .padding(.bottom, 14)
        }
    }
}
