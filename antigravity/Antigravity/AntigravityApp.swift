import SwiftUI
import UIKit

@main
struct AntigravityApp: App {
    var body: some Scene {
        WindowGroup {
            FleetRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct AgyNode: Identifiable, Hashable {
    let id: String
    let number: String
    let title: String
    let subtitle: String
    let host: String
    let port: Int
    let icon: String
}

struct ChatMessageItem: Identifiable, Hashable {
    let id = UUID()
    let role: String
    let text: String
    let thinking: String
    let time: String
}

@MainActor
final class FleetViewModel: ObservableObject {
    let nodes: [AgyNode] = [
        AgyNode(id: "win", number: "#1", title: "Windows PC", subtitle: "desktop-81e1rf4 • RTX/4K", host: "100.102.4.54", port: 9090, icon: "desktopcomputer"),
        AgyNode(id: "linux", number: "#2", title: "Linux Bazzite", subtitle: "bazzite • Gaming OS", host: "100.79.246.119", port: 9091, icon: "terminal.fill"),
        AgyNode(id: "truenas", number: "#3", title: "TrueNAS 24/7", subtitle: "storage_pool • ZFS/Docker", host: "100.85.127.42", port: 9092, icon: "externaldrive.fill.badge.wifi")
    ]

    @Published var selectedNode: AgyNode
    @Published var onlineMap: [String: Bool] = ["win": false, "linux": false, "truenas": false]
    @Published var summaryMap: [String: String] = [:]
    @Published var messages: [ChatMessageItem] = []
    @Published var workspaces: [String] = []
    @Published var screenImage: UIImage? = nil
    @Published var isBusy: Bool = false
    @Published var promptText: String = ""
    @Published var execCommand: String = ""
    @Published var execOutput: String = "Ready. Select a quick command or enter a shell command below."

    init() {
        selectedNode = AgyNode(id: "truenas", number: "#3", title: "TrueNAS 24/7", subtitle: "storage_pool • ZFS/Docker", host: "100.85.127.42", port: 9092, icon: "externaldrive.fill.badge.wifi")
    }

    func baseURL(for node: AgyNode) -> String {
        "http://\(node.host):\(node.port)"
    }

    func refreshAllStatus() async {
        for n in nodes {
            let ok = await probeNode(n)
            onlineMap[n.id] = ok
        }
        await loadNodeState(selectedNode)
    }

    func probeNode(_ node: AgyNode) async -> Bool {
        guard let url = URL(string: "\(baseURL(for: node))/api/antigravity/state") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let sum = json["summary"] as? String {
                    summaryMap[node.id] = sum
                } else if let osName = json["os"] as? String {
                    summaryMap[node.id] = osName
                }
            }
            return true
        } catch {
            return false
        }
    }

    func selectNode(_ node: AgyNode) {
        selectedNode = node
        screenImage = nil
        Task {
            await loadNodeState(node)
            await fetchScreen()
        }
    }

    func loadNodeState(_ node: AgyNode) async {
        guard let url = URL(string: "\(baseURL(for: node))/api/antigravity/state") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                onlineMap[node.id] = false
                return
            }
            onlineMap[node.id] = true
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let sum = json["summary"] as? String {
                summaryMap[node.id] = sum
            }
            if let ws = json["workspaces"] as? [String] {
                workspaces = ws
            }
            var parsed: [ChatMessageItem] = []
            if let steps = json["steps"] as? [[String: Any]], !steps.isEmpty {
                for s in steps {
                    let typeStr = (s["type"] as? String) ?? ""
                    let sourceStr = (s["source"] as? String) ?? ""
                    let isUser = typeStr == "USER_INPUT" || sourceStr == "USER_EXPLICIT"
                    let content = (s["content"] as? String) ?? ""
                    let thinking = (s["thinking"] as? String) ?? ""
                    let created = (s["created_at"] as? String) ?? ""
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parsed.append(ChatMessageItem(role: isUser ? "user" : "assistant", text: content, thinking: thinking, time: created))
                    }
                }
            } else if let convs = json["conversations"] as? [[String: Any]],
                      let first = convs.first,
                      let msgs = first["messages"] as? [[String: Any]] {
                for m in msgs {
                    let role = (m["role"] as? String) ?? "assistant"
                    let text = (m["text"] as? String) ?? ""
                    let time = (m["time"] as? String) ?? ""
                    if !text.isEmpty {
                        parsed.append(ChatMessageItem(role: role, text: text, thinking: "", time: time))
                    }
                }
            }
            if !parsed.isEmpty {
                messages = parsed
            }
        } catch {
            onlineMap[node.id] = false
        }
    }

    func sendPrompt(_ customPrompt: String? = nil) async {
        let text = (customPrompt ?? promptText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if customPrompt == nil { promptText = "" }
        messages.append(ChatMessageItem(role: "user", text: text, thinking: "", time: "Now"))
        isBusy = true
        defer { isBusy = false }

        guard let url = URL(string: "\(baseURL(for: selectedNode))/api/antigravity/chat") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 35
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": text, "message": text])

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let reply = json["reply"] as? String {
                    var think = ""
                    if let step = json["step"] as? [String: Any], let t = step["thinking"] as? String {
                        think = t
                    }
                    messages.append(ChatMessageItem(role: "assistant", text: reply, thinking: think, time: "Just now"))
                } else if let out = json["output"] as? String {
                    messages.append(ChatMessageItem(role: "assistant", text: out, thinking: "", time: "Just now"))
                }
            }
            await loadNodeState(selectedNode)
        } catch {
            messages.append(ChatMessageItem(role: "assistant", text: "Connection error: \(error.localizedDescription)", thinking: "", time: "Error"))
        }
    }

    func fetchScreen() async {
        guard let url = URL(string: "\(baseURL(for: selectedNode))/api/antigravity/screen?t=\(Int(Date().timeIntervalSince1970))") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let img = UIImage(data: data) {
                screenImage = img
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let b64 = json["image"] as? String {
                let clean = b64.replacingOccurrences(of: "data:image/png;base64,", with: "")
                               .replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
                if let decoded = Data(base64Encoded: clean), let img = UIImage(data: decoded) {
                    screenImage = img
                }
            }
        } catch {}
    }

    func runExec(_ command: String) async {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        isBusy = true
        execOutput = "$ \(cmd)\nRunning on \(selectedNode.title)..."
        defer { isBusy = false }

        guard let url = URL(string: "\(baseURL(for: selectedNode))/api/antigravity/exec") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd, "timeout": 25])

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let out = (json["output"] as? String) ?? (json["stdout"] as? String) ?? (json["stderr"] as? String) ?? "Done (no output)"
                execOutput = "$ \(cmd)\n\n\(out)"
            } else if let raw = String(data: data, encoding: .utf8) {
                execOutput = "$ \(cmd)\n\n\(raw)"
            }
        } catch {
            execOutput = "$ \(cmd)\n\nError: \(error.localizedDescription)"
        }
    }
}

struct FleetRootView: View {
    @StateObject private var vm = FleetViewModel()
    @State private var selectedTab: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Inline Square 3-Node Selector Bar
                HStack(spacing: 8) {
                    ForEach(vm.nodes) { node in
                        let isSelected = vm.selectedNode.id == node.id
                        let isOnline = vm.onlineMap[node.id] ?? false
                        Button {
                            vm.selectNode(node)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(isOnline ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text("\(node.number) \(node.title)")
                                        .font(.system(size: 12, weight: .bold))
                                        .lineLimit(1)
                                }
                                Text(vm.summaryMap[node.id] ?? node.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.cyan.opacity(0.22) : Color(white: 0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(red: 0.05, green: 0.07, blue: 0.13))

                TabView(selection: $selectedTab) {
                    AgentChatTabView(vm: vm)
                        .tabItem {
                            Label("Agent Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .tag(0)

                    LiveScreenTabView(vm: vm)
                        .tabItem {
                            Label("Live Screen", systemImage: "tv.and.mediabox")
                        }
                        .tag(1)

                    RemoteExecTabView(vm: vm)
                        .tabItem {
                            Label("Exec Shell", systemImage: "apple.terminal.fill")
                        }
                        .tag(2)
                }
            }
            .navigationTitle("Antigravity Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refreshAllStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await vm.refreshAllStatus()
            }
        }
    }
}

struct AgentChatTabView: View {
    @ObservedObject var vm: FleetViewModel
    let quickPrompts = [
        "Full system health report",
        "Check ZFS pool & disk space",
        "List running Docker containers",
        "Check NZBGet / Sonarr / Radarr queue",
        "Check camera & patrol status"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickPrompts, id: \.self) { chip in
                        Button {
                            Task { await vm.sendPrompt(chip) }
                        } label: {
                            Text(chip)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.cyan.opacity(0.16)))
                                .overlay(Capsule().stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if vm.messages.isEmpty {
                            Text("Connected to \(vm.selectedNode.title) (\(vm.selectedNode.host):\(vm.selectedNode.port)). Send a prompt below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 30)
                        }
                        ForEach(vm.messages) { msg in
                            VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 4) {
                                HStack {
                                    Text(msg.role == "user" ? "YOU" : vm.selectedNode.title.uppercased())
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(msg.role == "user" ? Color.cyan : Color.green)
                                    Spacer()
                                    Text(msg.time)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                if !msg.thinking.isEmpty {
                                    Text("💭 \(msg.thinking)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                                }
                                Text(msg.text)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(msg.role == "user" ? Color.cyan.opacity(0.18) : Color(white: 0.14))
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask \(vm.selectedNode.title)...", text: $vm.promptText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await vm.sendPrompt() }
                } label: {
                    if vm.isBusy {
                        ProgressView()
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.cyan))
                            .foregroundStyle(.black)
                    }
                }
                .disabled(vm.isBusy)
            }
            .padding(12)
            .background(Color(white: 0.1))
        }
    }
}

struct LiveScreenTabView: View {
    @ObservedObject var vm: FleetViewModel
    @State private var autoRefresh = true
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(vm.selectedNode.title) Live Viewport")
                    .font(.subheadline.bold())
                Spacer()
                Toggle("Auto 3s", isOn: $autoRefresh)
                    .labelsHidden()
                Text("Auto")
                    .font(.caption)
                Button("Snap") {
                    Task { await vm.fetchScreen() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let img = vm.screenImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in zoom = max(1.0, min(val, 4.0)) }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation { zoom = zoom > 1.0 ? 1.0 : 2.2 }
                        }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: vm.selectedNode.icon)
                        .font(.system(size: 46))
                        .foregroundStyle(.cyan)
                    Text(vm.selectedNode.id == "truenas" ? "TrueNAS 24/7 Headless HUD Active" : "Tap Snap to load live desktop stream")
                        .font(.headline)
                    Text(vm.summaryMap[vm.selectedNode.id] ?? vm.selectedNode.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !vm.workspaces.isEmpty {
                        Text("Workspaces: \(vm.workspaces.joined(separator: " • "))")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.11)))
                .padding(12)
            }
        }
        .task(id: vm.selectedNode.id) {
            await vm.fetchScreen()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if autoRefresh {
                    await vm.fetchScreen()
                }
            }
        }
    }
}

struct RemoteExecTabView: View {
    @ObservedObject var vm: FleetViewModel
    let presets = [
        ("ZFS Pool", "zpool status storage_pool"),
        ("Docker PS", "docker ps --format 'table {{.Names}}\t{{.Status}}'"),
        ("Disk Free", "df -h"),
        ("Tailscale", "tailscale status"),
        ("Uptime", "uptime")
    ]

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { item in
                        Button(item.0) {
                            vm.execCommand = item.1
                            Task { await vm.runExec(item.1) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                TextField("Command on \(vm.selectedNode.title)...", text: $vm.execCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.subheadline, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Run") {
                    Task { await vm.runExec(vm.execCommand) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)

            ScrollView {
                Text(vm.execOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}
