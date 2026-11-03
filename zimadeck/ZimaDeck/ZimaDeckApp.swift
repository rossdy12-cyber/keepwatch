import SwiftUI
import WebKit

struct ZimaWebView: UIViewRepresentable {
    let urlString: String
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        if let u = URL(string: urlString) { w.load(URLRequest(url: u)) }
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
class ZimaDeckStore: ObservableObject {
    @Published var zimaIP: String = "100.82.255.29"
    @Published var truenasIP: String = "100.85.127.42"
    @Published var rustdeskPublicKey: String = "obdDqkfFFVv2xnIAxmeSa6H1o2JTgEAMlliSFJGTEYY="
    @Published var statusBanner: String = "Zimaboard (100.82.255.29) + RustDesk + Komga Ready"
    @Published var rustdeskLogs: String = "Tap Refresh to check hbbs/hbbr relay status."

    func checkZimaAndRustDesk() async {
        guard let url = URL(string: "http://\(truenasIP):9092/api/antigravity/exec") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "ping -c 1 100.82.255.29 2>&1; echo '=== RUSTDESK SERVER ==='; sudo docker ps --filter name=rustdesk --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let out = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? ""
            rustdeskLogs = out.isEmpty ? "Online" : out
        }
    }
}

@main
struct ZimaDeckApp: App {
    @StateObject private var store = ZimaDeckStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                ZimaServicesTab()
                    .tabItem { Label("Zimaboard", systemImage: "server.rack") }
                KomgaReaderTab()
                    .tabItem { Label("Komga Books", systemImage: "book.closed.fill") }
                RustDeskHubTab()
                    .tabItem { Label("RustDesk Relay", systemImage: "display.and.arrow.down") }
            }
            .environmentObject(store)
            .tint(.mint)
            .preferredColorScheme(.dark)
        }
    }
}

struct ZimaServicesTab: View {
    @EnvironmentObject var store: ZimaDeckStore
    @State private var svc: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Zimaboard Service", selection: $svc) {
                Text("Zima OS (:442)").tag(0)
                Text("Portainer (:9000)").tag(1)
                Text("Nextcloud (:10081)").tag(2)
                Text("Immich (:2283)").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(10)

            if svc == 0 {
                ZimaWebView(urlString: "https://lnas.nas-server.co.uk")
                    .id("zima-os")
            } else if svc == 1 {
                ZimaWebView(urlString: "http://\(store.zimaIP):9000")
                    .id("zima-port")
            } else if svc == 2 {
                ZimaWebView(urlString: "http://\(store.zimaIP):10081")
                    .id("zima-nc")
            } else {
                ZimaWebView(urlString: "http://\(store.zimaIP):2283")
                    .id("zima-immich")
            }
        }
    }
}

struct KomgaReaderTab: View {
    @EnvironmentObject var store: ZimaDeckStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "book.fill").foregroundColor(.mint)
                Text("Komga Comics, Manga & eBook Server (:30048)")
                    .font(.caption.bold())
                Spacer()
            }
            .padding(8)
            .background(Color.mint.opacity(0.16))

            ZimaWebView(urlString: "http://\(store.truenasIP):30048")
        }
    }
}

struct RustDeskHubTab: View {
    @EnvironmentObject var store: ZimaDeckStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Self-Hosted RustDesk Server (hbbs + hbbr)")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ID / Relay Server (Tailscale):")
                                .font(.caption).foregroundColor(.gray)
                            Spacer()
                            Text("100.85.127.42")
                                .font(.caption.bold().monospaced())
                            Button("Copy") { UIPasteboard.general.string = "100.85.127.42" }
                                .font(.caption2.bold()).foregroundColor(.mint)
                        }
                        HStack {
                            Text("ID / Relay Server (LAN):")
                                .font(.caption).foregroundColor(.gray)
                            Spacer()
                            Text("38.9.96.58")
                                .font(.caption.bold().monospaced())
                            Button("Copy") { UIPasteboard.general.string = "38.9.96.58" }
                                .font(.caption2.bold()).foregroundColor(.mint)
                        }
                        Divider()
                        Text("Public Key:")
                            .font(.caption).foregroundColor(.gray)
                        Text(store.rustdeskPublicKey)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.mint)
                        Button {
                            UIPasteboard.general.string = store.rustdeskPublicKey
                            store.statusBanner = "Copied RustDesk Public Key to clipboard!"
                        } label: {
                            Label("Copy RustDesk Public Key", systemImage: "doc.on.doc.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(10)
                                .background(Color.mint)
                                .foregroundColor(.black)
                                .cornerRadius(8)
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(12)

                    HStack {
                        Text("Zimaboard & RustDesk Live Status")
                            .font(.subheadline.bold())
                        Spacer()
                        Button("Refresh") {
                            Task { await store.checkZimaAndRustDesk() }
                        }
                        .font(.caption.bold())
                    }

                    Text(store.rustdeskLogs)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("RustDesk & Zima")
            .task {
                await store.checkZimaAndRustDesk()
            }
        }
    }
}
