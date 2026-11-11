import SwiftUI
import WebKit

/// In-app video call: loads the self-hosted gothic WebRTC call page (served by jarvis-core) in a web view,
/// granting it camera + microphone. Works iPhone ↔ Windows because both sides load the same page.
struct CallView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = store.callURL {
                CallWebView(url: url).ignoresSafeArea()
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
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline).padding(10)
                    .background(Circle().fill(.black.opacity(0.5)))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 16).padding(.top, 8)
        }
    }
}

struct CallWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKUIDelegate {
        /// Auto-grant camera/mic to the trusted homelab call page (iOS 15+).
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}
