import SwiftUI
import WebKit

struct PhotoServiceCard: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let urlString: String
    let containerName: String
    let icon: String
    let accent: Color
}

@MainActor
class PhotoPulseStore: ObservableObject {
    @Published var truenasHost: String = "100.85.127.42"
    @Published var zimaHost: String = "100.82.255.29"
    @Published var statusBanner: String = "Connected to TrueNAS Photo Pipeline"
    @Published var twoFactorCode: String = ""
    @Published var selectedContainer: String = "icloudpd"
    @Published var containerLogs: String = "Tap any daemon below to inspect live sync & face-clustering logs."
    @Published var isBusy: Bool = false

    let daemons: [(id: String, name: String, desc: String, icon: String)] = [
        ("icloudpd", "iCloud Downloader (Personal)", "Full personal iCloud photo stream -> TrueNAS", "icloud.and.arrow.down.fill"),
        ("icloudpd-shared", "iCloud Downloader (Shared)", "Shared iCloud albums -> TrueNAS", "person.2.crop.square.stack.fill"),
        ("icloudpd-hidden", "iCloud Downloader (Hidden)", "Hidden iCloud vault -> TrueNAS", "eye.slash.circle.fill"),
        ("album-ross", "Immich Face -> Album (Ross)", "Auto-assigns Ross face matches to album", "face.smiling.inverse"),
        ("album-ross-and-lauren", "Immich Face -> Album (Ross & Lauren)", "Auto-assigns Ross & Lauren photos to shared album", "heart.circle.fill"),
        ("immichframe", "ImmichFrame Digital Frame (:9180)", "Slideshow frame pulling from Immich", "photo.artframe"),
        ("damselfly", "Damselfly Fast Indexer (:6363)", "Metadata & face/keyword photo indexer", "sparkle.magnifyingglass")
    ]

    func execTrueNAS(_ cmd: String) async -> String {
        guard let url = URL(string: "http://\(truenasHost):9092/api/antigravity/exec") else { return "Bad URL" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let out = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? ""
                let err = (obj["stderr"] as? String) ?? ""
                return (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(data: data, encoding: .utf8) ?? "OK"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func fetchLogs(_ container: String) async {
        isBusy = true
        defer { isBusy = false }
        let out = await execTrueNAS("sudo docker logs --tail 60 \(container) 2>&1")
        containerLogs = out.isEmpty ? "No recent output from \(container)." : out
        statusBanner = "Loaded logs for \(container)"
    }

    func restartDaemon(_ container: String) async {
        isBusy = true
        defer { isBusy = false }
        let out = await execTrueNAS("sudo docker restart \(container) 2>&1")
        statusBanner = "Restarted \(container): \(out)"
        await fetchLogs(container)
    }

    func submitApple2FA() async {
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            statusBanner = "Enter your 6-digit Apple 2FA code first"
            return
        }
        isBusy = true
        defer { isBusy = false }
        let cmd = "echo '\(code)' | sudo docker attach --sig-proxy=false \(selectedContainer) 2>&1 || sudo docker exec \(selectedContainer) sh -c 'echo \(code) > /tmp/2fa_code' 2>&1"
        let out = await execTrueNAS(cmd)
        statusBanner = "Submitted 2FA code \(code) to \(selectedContainer)"
        containerLogs = out.isEmpty ? "Submitted code \(code) to \(selectedContainer)" : out
        twoFactorCode = ""
    }
}

struct PhotoWebView: UIViewRepresentable {
    let urlString: String
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .black
        if let u = URL(string: urlString) {
            web.load(URLRequest(url: u))
        }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct PhotoPulseApp: App {
    @StateObject private var store = PhotoPulseStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                PhotoSyncDaemonsView()
                    .tabItem { Label("Sync & AI", systemImage: "icloud.and.arrow.down.fill") }
                PhotoFramesView()
                    .tabItem { Label("Live Frames", systemImage: "photo.artframe") }
                ImmichDualBrowserView()
                    .tabItem { Label("Immich & Damselfly", systemImage: "photo.on.rectangle.angled") }
            }
            .environmentObject(store)
            .tint(.pink)
            .preferredColorScheme(.dark)
        }
    }
}

struct PhotoSyncDaemonsView: View {
    @EnvironmentObject var store: PhotoPulseStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "sparkles.tv.fill").foregroundColor(.pink)
                        Text(store.statusBanner).font(.caption).foregroundColor(.white)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.pink.opacity(0.16))
                    .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Apple iCloudPD 2FA Cookie Refresher")
                            .font(.headline)
                        Picker("Target Stream", selection: $store.selectedContainer) {
                            Text("Personal (icloudpd)").tag("icloudpd")
                            Text("Shared (icloudpd-shared)").tag("icloudpd-shared")
                            Text("Hidden (icloudpd-hidden)").tag("icloudpd-hidden")
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            TextField("6-Digit Apple 2FA Code", text: $store.twoFactorCode)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            Button("Submit 2FA") {
                                Task { await store.submitApple2FA() }
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.pink)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(14)

                    Text("Photo Sync & Face-to-Album Daemons")
                        .font(.headline)

                    ForEach(store.daemons, id: \.id) { d in
                        HStack(spacing: 12) {
                            Image(systemName: d.icon)
                                .font(.title2)
                                .foregroundColor(.pink)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.subheadline.bold()).foregroundColor(.white)
                                Text(d.desc).font(.caption2).foregroundColor(.gray)
                            }
                            Spacer()
                            Button("Logs") {
                                Task { await store.fetchLogs(d.id) }
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .cornerRadius(6)

                            Button("Run/Restart") {
                                Task { await store.restartDaemon(d.id) }
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.pink.opacity(0.28))
                            .foregroundColor(.pink)
                            .cornerRadius(6)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                    }

                    Text("Live Container Console Output")
                        .font(.subheadline.bold())
                    Text(store.containerLogs)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("PhotoPulse AI")
        }
    }
}

struct PhotoFramesView: View {
    @EnvironmentObject var store: PhotoPulseStore
    @State private var mode: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Display Mode", selection: $mode) {
                Text("ImmichFrame (:9180)").tag(0)
                Text("Immich Kiosk (:30042)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(10)

            if mode == 0 {
                PhotoWebView(urlString: "http://\(store.truenasHost):9180")
                    .id("frame9180")
            } else {
                PhotoWebView(urlString: "http://\(store.truenasHost):30042")
                    .id("kiosk30042")
            }
        }
    }
}

struct ImmichDualBrowserView: View {
    @EnvironmentObject var store: PhotoPulseStore
    @State private var target: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Server", selection: $target) {
                Text("TrueNAS Immich").tag(0)
                Text("Zimaboard Immich").tag(1)
                Text("Damselfly (:6363)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(10)

            if target == 0 {
                PhotoWebView(urlString: "http://\(store.truenasHost):30041")
                    .id("immich-main")
            } else if target == 1 {
                PhotoWebView(urlString: "http://\(store.zimaHost):2283")
                    .id("immich-zima")
            } else {
                PhotoWebView(urlString: "http://\(store.truenasHost):6363")
                    .id("damselfly")
            }
        }
    }
}
