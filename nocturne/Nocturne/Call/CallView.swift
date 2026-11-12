import SwiftUI
import WebKit

/// In-app video call: loads the self-hosted gothic WebRTC call page (served by jarvis-core) in a web view,
/// granting it camera + microphone. Works iPhone ↔ Windows because both sides load the same page.
struct CallView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var call = CallController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = store.callURL {
                CallWebView(url: url, controller: call, onEnded: { dismiss() }).ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text("Set your chat relay in the Altar to make a video call.")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(40)
            }
        }
        .overlay(alignment: .topLeading) {
            // Hang up properly (tells the other side + releases camera/mic) before closing.
            Button { call.hangUp { dismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.headline).padding(10)
                    .background(Circle().fill(.black.opacity(0.5)))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 16).padding(.top, 8)
        }
    }
}

/// Lets the SwiftUI close button drive the call page's own hang-up.
final class CallController: ObservableObject {
    weak var webView: WKWebView?
    private var ending = false

    /// Presses the page's hang-up button (sends "bye" to the other side, stops camera/mic), then
    /// force-stops capture natively in case the page didn't, then runs `done`.
    func hangUp(_ done: @escaping () -> Void) {
        guard !ending else { return }
        ending = true
        guard let web = webView else { done(); return }
        web.evaluateJavaScript("(function(){var b=document.getElementById('end'); if(b) b.click();})()") { _, _ in
            Self.stopCapture(web)
            // Brief pause so the hang-up request leaves before the web view is torn down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
        }
    }

    static func stopCapture(_ web: WKWebView) {
        if #available(iOS 15.0, *) {
            web.setCameraCaptureState(.none, completionHandler: nil)
            web.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }
}

struct CallWebView: UIViewRepresentable {
    let url: URL
    let controller: CallController
    let onEnded: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        controller.webView = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onEnded: onEnded) }

    /// Safety net: if the view goes away by any other route (swipe-down, app navigation), still hang up.
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("(function(){var b=document.getElementById('end'); if(b) b.click();})()", completionHandler: nil)
        CallController.stopCapture(web)
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        let onEnded: () -> Void
        private var didEnd = false
        init(onEnded: @escaping () -> Void) { self.onEnded = onEnded }

        /// The call page navigates to about:blank after hang-up — close the call screen instead of showing a blank view.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.cancel)
                CallController.stopCapture(webView)
                if !didEnd { didEnd = true; DispatchQueue.main.async(execute: onEnded) }
                return
            }
            decisionHandler(.allow)
        }

        /// window.close() from the page also ends the call screen.
        func webViewDidClose(_ webView: WKWebView) {
            CallController.stopCapture(webView)
            if !didEnd { didEnd = true; DispatchQueue.main.async(execute: onEnded) }
        }

        /// Auto-grant camera/mic to the trusted homelab call page (iOS 15+).
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}
