import SwiftUI
import WebKit

/// Displays a tab's live WKWebView. The parent keys this by tab id so switching tabs swaps the web view.
struct WebContainer: UIViewRepresentable {
    let tab: BrowserTab
    func makeUIView(context: Context) -> WKWebView { tab.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
