import SwiftUI
import WebKit

@MainActor
class SoulSeekrStore: ObservableObject {
    @Published var host: String = "100.85.127.42"
    var slskdApiKey: String { StoredSecret.slskdApiKey.value }
    var lidarrApiKey: String { StoredSecret.lidarrApiKey.value }
    @Published var searchQuery: String = ""
    @Published var statusBanner: String = "slskd (:5030) + Hearr (:5070) + Soularr (:8265) Ready"
    @Published var soularrLogs: String = "Tap 'Sync Wanted List' or 'View Soularr Logs' to inspect P2P grabs."
    @Published var isBusy: Bool = false

    func execTrueNAS(_ cmd: String) async -> String {
        guard let url = URL(string: "http://\(host):9092/api/antigravity/exec") else { return "Bad URL" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let out = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? ""
            let err = (obj["stderr"] as? String) ?? ""
            return (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Dispatched."
    }

    func triggerSoularrSync() async {
        isBusy = true
        defer { isBusy = false }
        let out = await execTrueNAS("sudo docker restart soularr 2>&1 && sleep 2 && sudo docker logs --tail 45 soularr 2>&1")
        soularrLogs = out
        statusBanner = "Soularr P2P Wanted Sync Triggered!"
    }

    func fetchSlskdStatus() async {
        isBusy = true
        defer { isBusy = false }
        let out = await execTrueNAS("sudo docker logs --tail 40 slskd 2>&1; echo '=== SOULARR ==='; sudo docker logs --tail 35 soularr 2>&1")
        soularrLogs = out
        statusBanner = "Updated slskd + Soularr P2P logs"
    }

    func triggerSlskdSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        guard let url = URL(string: "http://\(host):5030/api/v0/searches") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(slskdApiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["searchText": q])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            statusBanner = "Dispatched Soulseek P2P search for '\(q)' (HTTP \(code))"
        } catch {
            statusBanner = "Search sent: \(error.localizedDescription)"
        }
    }
}

struct SoulWebView: UIViewRepresentable {
    let urlString: String
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        if let u = URL(string: urlString) { w.load(URLRequest(url: u)) }
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct SoulSeekrApp: App {
    @StateObject private var store = SoulSeekrStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                HearrPortalTab()
                    .tabItem { Label("Hearr (:5070)", systemImage: "music.mic") }
                SlskdWebTab()
                    .tabItem { Label("slskd (:5030)", systemImage: "waveform.badge.magnifyingglass") }
                SoularrControlTab()
                    .tabItem { Label("Soularr Bridge", systemImage: "bolt.horizontal.circle.fill") }
            }
            .environmentObject(store)
            .tint(.purple)
            .preferredColorScheme(.dark)
        }
    }
}

struct HearrPortalTab: View {
    @EnvironmentObject var store: SoulSeekrStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.open.fill").foregroundColor(.purple)
                Text("Hearr Music Request Portal")
                    .font(.caption2.bold())
                Spacer()
                SecretCopyButton(secret: .hearrPin, label: "Copy PIN")
                .font(.caption2.bold())
                .foregroundColor(.purple)
            }
            .padding(8)
            .background(Color.purple.opacity(0.18))

            SoulWebView(urlString: "https://hearr.nas-server.co.uk")
        }
    }
}

struct SlskdWebTab: View {
    @EnvironmentObject var store: SoulSeekrStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("slskd P2P Daemon • User: slskd")
                    .font(.caption2.bold())
                Spacer()
                SecretCopyButton(secret: .slskdPassword, label: "Copy Pass")
                .font(.caption2.bold())
                .foregroundColor(.purple)
            }
            .padding(8)
            .background(Color.purple.opacity(0.18))

            SoulWebView(urlString: "https://slskd.nas-server.co.uk")
        }
    }
}

struct SoularrControlTab: View {
    @EnvironmentObject var store: SoulSeekrStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.statusBanner)
                        .font(.caption.bold())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.2))
                        .cornerRadius(10)

                    HStack {
                        TextField("Direct Soulseek P2P Search (Artist - Album / Track)", text: $store.searchQuery)
                            .textFieldStyle(.roundedBorder)
                        Button("Search P2P") {
                            Task { await store.triggerSlskdSearch() }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await store.triggerSoularrSync() }
                        } label: {
                            Label("Sync Lidarr -> Soulseek Now", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        Button {
                            Task { await store.fetchSlskdStatus() }
                        } label: {
                            Label("Refresh Logs", systemImage: "doc.text.magnifyingglass")
                                .font(.caption.bold())
                                .padding(12)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }

                    Text("Soularr & slskd Live Activity Log")
                        .font(.subheadline.bold())

                    Text(store.soularrLogs)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("SoulSeekr P2P")
            .task {
                await store.fetchSlskdStatus()
            }
        }
    }
}
