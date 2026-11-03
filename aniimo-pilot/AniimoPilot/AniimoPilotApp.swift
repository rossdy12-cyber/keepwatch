import SwiftUI

@main
struct AniimoPilotApp: App {
    var body: some Scene {
        WindowGroup {
            AniimoPilotRootView()
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AniimoViewModel: ObservableObject {
    @Published var winHost = "http://100.102.4.54:9090"
    @Published var gameScreen: UIImage? = nil
    @Published var botStatus: String = "Ready to connect to Windows PC (100.102.4.54:9090)"
    @Published var logOutput: String = ""
    @Published var autoStream: Bool = true

    func refreshScreen() async {
        guard let url = URL(string: "\(winHost)/api/antigravity/screen?t=\(Int(Date().timeIntervalSince1970))") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let img = UIImage(data: data) {
            gameScreen = img
        }
    }

    func runBotAction(_ label: String, command: String) async {
        botStatus = "Running: \(label)..."
        guard let url = URL(string: "\(winHost)/api/antigravity/exec") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": command])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let out = json["output"] as? String {
                logOutput = out
                botStatus = "\(label) complete"
            }
            await refreshScreen()
        } catch {
            botStatus = "Error: \(error.localizedDescription)"
        }
    }
}

struct AniimoPilotRootView: View {
    @StateObject private var vm = AniimoViewModel()

    let actions: [(String, String, String)] = [
        ("Start Farm Bot", "play.fill", "powershell -Command \"Start-Process python -ArgumentList 'C:\\Users\\Ross_Dymond\\.gemini\\antigravity\\scratch\\aniimo-farm-bot\\bot.py' -WindowStyle Hidden; Write-Output 'Aniimo Farm Bot Started'\""),
        ("Stop Farm Bot", "stop.fill", "powershell -Command \"Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*aniimo*' } | Invoke-CimMethod -MethodName Terminate; Write-Output 'Stopped Aniimo Farm Bot'\""),
        ("Check Bot Status", "waveform.path.ecg", "powershell -Command \"Get-Process | Where-Object { $_.ProcessName -match 'python|Aniimo' } | Select-Object Id, ProcessName, CPU | Format-Table -AutoSize\""),
        ("Refresh Screenshot", "camera.viewfinder", "echo 'Refreshing live screen'")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.black)
                            .frame(height: 225)
                        if let img = vm.gameScreen {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.mint)
                                Text("Waiting for Windows PC Viewport...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    HStack {
                        Circle().fill(Color.mint).frame(width: 8, height: 8)
                        Text(vm.botStatus)
                            .font(.caption.bold())
                        Spacer()
                        Toggle("Live", isOn: $vm.autoStream)
                            .labelsHidden()
                    }
                    .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(actions, id: \.0) { act in
                            Button {
                                Task { await vm.runBotAction(act.0, command: act.2) }
                            } label: {
                                HStack {
                                    Image(systemName: act.1)
                                    Text(act.0)
                                        .font(.caption.bold())
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.mint.opacity(0.18)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mint.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)

                    if !vm.logOutput.isEmpty {
                        Text(vm.logOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.mint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Aniimo Pilot")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                while !Task.isCancelled {
                    if vm.autoStream {
                        await vm.refreshScreen()
                    }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
            }
        }
    }
}
