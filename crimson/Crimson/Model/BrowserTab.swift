import SwiftUI
import WebKit

/// One browser tab: owns its WKWebView and tracks its navigation state. Acts as its own navigation delegate.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    @Published var title = "New Tab"
    @Published var urlString = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var darkMode = false

    weak var store: BrowserStore?
    private var progressObs: NSKeyValueObservation?

    init(isPrivate: Bool, store: BrowserStore?) {
        self.isPrivate = isPrivate
        self.store = store
        let config = WKWebViewConfiguration()
        if isPrivate { config.websiteDataStore = .nonPersistent() }
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        AdBlock.apply(to: webView.configuration.userContentController)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.progress = wv.estimatedProgress }
        }
    }

    func load(_ text: String) {
        webView.load(URLRequest(url: BrowserTab.resolveURL(text)))
    }

    /// Turns typed text into a URL: a web address if it looks like one, otherwise a DuckDuckGo search.
    static func resolveURL(_ text: String) -> URL {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), let s = u.scheme, s == "http" || s == "https" { return u }
        if t.contains("."), !t.contains(" "), let u = URL(string: "https://" + t) { return u }
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        return URL(string: "https://duckduckgo.com/?q=\(q)") ?? URL(string: "https://duckduckgo.com")!
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadOrStop() { if isLoading { webView.stopLoading() } else { webView.reload() } }

    func toggleDark() {
        darkMode.toggle()
        if darkMode { webView.evaluateJavaScript(Injection.darkCSS, completionHandler: nil) } else { webView.reload() }
    }

    func reader() { webView.evaluateJavaScript(Injection.reader, completionHandler: nil) }

    private func sync() {
        let t = webView.title ?? ""
        title = t.isEmpty ? (webView.url?.host ?? "New Tab") : t
        if let u = webView.url?.absoluteString { urlString = u }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

extension BrowserTab: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.isLoading = true }
    }
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.sync()
            if self.darkMode { webView.evaluateJavaScript(Injection.darkCSS, completionHandler: nil) }
            if let url = webView.url?.absoluteString, let js = UserScriptStore.shared.injection(for: url) {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            if !self.isPrivate, let url = webView.url?.absoluteString, !url.isEmpty {
                self.store?.recordHistory(title: self.title, url: url)
            }
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isLoading = false; self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isLoading = false; self.sync() }
    }
}
