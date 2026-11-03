import SwiftUI
import AVKit

@main
struct SentryCamApp: App {
    var body: some Scene {
        WindowGroup {
            SentryCamRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct FrigateEvent: Identifiable {
    let id: String
    let camera: String
    let label: String
    let score: Double
    let startTime: Double
}

@MainActor
final class SentryViewModel: ObservableObject {
    @Published var frigateBase = "http://100.85.127.42:5000"
    @Published var truenasAgent = "http://100.85.127.42:9092"
    @Published var cameras: [String] = ["tapo_cam", "ezviz_cam"]
    @Published var selectedCamera: String = "tapo_cam"
    @Published var liveFrame: UIImage? = nil
    @Published var events: [FrigateEvent] = []
    @Published var patrolStatus: String = "24/7 Tapo PTZ Patrol Active"
    @Published var selectedClipURL: URL? = nil

    func discoverCameras() async {
        guard let url = URL(string: "\(frigateBase)/api/config") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cams = json["cameras"] as? [String: Any], !cams.isEmpty {
            let names = Array(cams.keys).sorted()
            cameras = names
            if !names.contains(selectedCamera), let first = names.first {
                selectedCamera = first
            }
        }
    }

    func refreshLiveFrame() async {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "\(frigateBase)/api/\(selectedCamera)/latest.jpg?h=720&t=\(ts)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let img = UIImage(data: data) {
            liveFrame = img
        }
    }

    func loadEvents() async {
        guard let url = URL(string: "\(frigateBase)/api/events?limit=35") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var list: [FrigateEvent] = []
            for item in arr {
                if let id = item["id"] as? String {
                    let cam = (item["camera"] as? String) ?? "cam"
                    let lbl = (item["label"] as? String) ?? "object"
                    let score = (item["top_score"] as? Double) ?? (item["score"] as? Double) ?? 0.85
                    let st = (item["start_time"] as? Double) ?? Date().timeIntervalSince1970
                    list.append(FrigateEvent(id: id, camera: cam, label: lbl, score: score, startTime: st))
                }
            }
            events = list
        }
    }

    func sendPTZCommand(_ action: String) async {
        patrolStatus = "Sending PTZ: \(action)..."
        guard let url = URL(string: "\(truenasAgent)/api/antigravity/exec") else { return }
        let cmd: String
        switch action {
        case "patrol_on":
            cmd = "docker start tapo-patrol && echo 'Tapo Patrol Started'"
        case "patrol_off":
            cmd = "docker stop tapo-patrol && echo 'Tapo Patrol Paused'"
        default:
            cmd = "docker logs --tail 5 tapo-patrol 2>&1"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let out = json["stdout"] as? String {
            patrolStatus = out.isEmpty ? "PTZ \(action) complete" : out
        } else {
            patrolStatus = "PTZ \(action) sent"
        }
    }
}

struct SentryCamRootView: View {
    @StateObject private var vm = SentryViewModel()

    var body: some View {
        NavigationStack {
            TabView {
                SentryLiveTab(vm: vm)
                    .tabItem { Label("Live CCTV", systemImage: "video.fill") }

                SentryEventsTab(vm: vm)
                    .tabItem { Label("AI Events", systemImage: "figure.walk.motion") }
            }
            .navigationTitle("SentryCam NVR")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await vm.discoverCameras()
                await vm.loadEvents()
            }
        }
    }
}

struct SentryLiveTab: View {
    @ObservedObject var vm: SentryViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Camera", selection: $vm.selectedCamera) {
                    ForEach(vm.cameras, id: \.self) { cam in
                        Text(cam).tag(cam)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black)
                        .frame(height: 230)
                    if let img = vm.liveFrame {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Connecting to Frigate (\(vm.selectedCamera))...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)

                // Tapo PTZ Control Card
                VStack(spacing: 12) {
                    HStack {
                        Label("Tapo C200 PTZ & Patrol Control", systemImage: "dial.medium.fill")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    Text(vm.patrolStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button("Resume Patrol") { Task { await vm.sendPTZCommand("patrol_on") } }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        Button("Pause Patrol") { Task { await vm.sendPTZCommand("patrol_off") } }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        Button("Patrol Logs") { Task { await vm.sendPTZCommand("status") } }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .task(id: vm.selectedCamera) {
            while !Task.isCancelled {
                await vm.refreshLiveFrame()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}

struct SentryEventsTab: View {
    @ObservedObject var vm: SentryViewModel

    var body: some View {
        List(vm.events) { ev in
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: "\(vm.frigateBase)/api/events/\(ev.id)/thumbnail.jpg")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 72, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ev.label.capitalized)
                            .font(.subheadline.bold())
                        Text("\(Int(ev.score * 100))%")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.25)))
                    }
                    Text("\(ev.camera) • \(Date(timeIntervalSince1970: ev.startTime).formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let clipURL = URL(string: "\(vm.frigateBase)/api/events/\(ev.id)/clip.mp4") {
                    Link(destination: clipURL) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .refreshable {
            await vm.loadEvents()
        }
    }
}
