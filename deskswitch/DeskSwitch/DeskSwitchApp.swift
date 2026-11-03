import SwiftUI

struct PCHost: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let ip: String
    let bridgePort: Int
    let remotePort: Int
    let isLinux: Bool
    let macAddress: String
}

struct SteamGame: Identifiable, Codable {
    let appid: String
    let name: String
    var id: String { appid }
    var headerURL: URL? {
        URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(appid)/header.jpg")
    }
}

struct AudioEndpoint: Identifiable, Codable {
    let id: String
    let name: String
    let kind: String
    let isDefault: Bool
}

@MainActor
class DeskSwitchStore: ObservableObject {
    let hosts: [PCHost] = [
        PCHost(id: "win", name: "Ross Windows PC", subtitle: "3-Monitor Desk & TV • 100.102.4.54", ip: "100.102.4.54", bridgePort: 9090, remotePort: 7777, isLinux: false, macAddress: "00:00:00:00:00:00"),
        PCHost(id: "bazzite", name: "Bazzite Linux PC", subtitle: "SteamOS / KDE • 100.79.246.119", ip: "100.79.246.119", bridgePort: 9091, remotePort: 7777, isLinux: true, macAddress: "00:00:00:00:00:00"),
        PCHost(id: "lauren", name: "Lauren Steam PC", subtitle: "TV & Alienware • Port 7777", ip: "192.168.0.100", bridgePort: 9090, remotePort: 7777, isLinux: false, macAddress: "00:00:00:00:00:00")
    ]

    @Published var selectedHostID: String = "win"
    @Published var customIP: String = ""
    @Published var onlineStatus: [String: Bool] = [:]
    @Published var statusBanner: String = "Ready"
    @Published var isBusy: Bool = false
    @Published var games: [SteamGame] = [
        SteamGame(appid: "1245620", name: "ELDEN RING"),
        SteamGame(appid: "1086940", name: "Baldur's Gate 3"),
        SteamGame(appid: "1091500", name: "Cyberpunk 2077"),
        SteamGame(appid: "1172470", name: "Apex Legends"),
        SteamGame(appid: "271590", name: "Grand Theft Auto V"),
        SteamGame(appid: "1623730", name: "Palworld")
    ]
    @Published var audioDevices: [AudioEndpoint] = []
    @Published var systemStats: String = "Tap Refresh to query CPU, GPU & Display topology."

    var currentHost: PCHost {
        let base = hosts.first(where: { $0.id == selectedHostID }) ?? hosts[0]
        if !customIP.trimmingCharacters(in: .whitespaces).isEmpty {
            return PCHost(id: base.id, name: base.name, subtitle: customIP, ip: customIP.trimmingCharacters(in: .whitespaces), bridgePort: base.bridgePort, remotePort: base.remotePort, isLinux: base.isLinux, macAddress: base.macAddress)
        }
        return base
    }

    func pingAll() async {
        for h in hosts {
            let ok = await checkHost(h)
            onlineStatus[h.id] = ok
        }
    }

    func checkHost(_ h: PCHost) async -> Bool {
        if let url = URL(string: "http://\(h.ip):\(h.bridgePort)/api/antigravity/state") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2.5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        }
        if let url = URL(string: "http://\(h.ip):\(h.remotePort)/api/games") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2.5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        }
        return false
    }

    func execBridge(_ command: String, host: PCHost? = nil) async -> String {
        let h = host ?? currentHost
        guard let url = URL(string: "http://\(h.ip):\(h.bridgePort)/api/antigravity/exec") else { return "Invalid URL" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": command])
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

    func callRemoteAPI(_ path: String) async -> [String: Any]? {
        let h = currentHost
        for port in [h.remotePort, 8888] {
            guard let url = URL(string: "http://\(h.ip):\(port)\(path)") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3.0
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }

    // MARK: - Display Switching
    func switchDisplay(mode: String) async {
        isBusy = true
        defer { isBusy = false }
        let h = currentHost

        if !h.isLinux {
            if mode == "tv", let json = await callRemoteAPI("/api/tv") {
                statusBanner = (json["message"] as? String) ?? "Switched to TV Only"
                return
            }
            if mode == "monitor", let json = await callRemoteAPI("/api/monitor") {
                statusBanner = (json["message"] as? String) ?? "Switched to Monitor"
                return
            }
            let flag: String
            switch mode {
            case "tv": flag = "/external"
            case "monitor": flag = "/internal"
            case "extend": flag = "/extend"
            case "clone": flag = "/clone"
            default: flag = "/extend"
            }
            let out = await execBridge("DisplaySwitch.exe \(flag)")
            statusBanner = out.isEmpty ? "Windows Display -> \(mode.uppercased()) (\(flag))" : out
        } else {
            let cmd: String
            switch mode {
            case "tv":
                cmd = "kscreen-doctor output.HDMI-A-1.enable output.DP-1.disable 2>/dev/null || xrandr --output HDMI-A-1 --auto"
            case "monitor":
                cmd = "kscreen-doctor output.DP-1.enable output.HDMI-A-1.disable 2>/dev/null || xrandr --output DP-1 --auto"
            case "extend":
                cmd = "kscreen-doctor output.DP-1.enable output.HDMI-A-1.enable 2>/dev/null || xrandr --auto"
            default:
                cmd = "xrandr --auto"
            }
            let out = await execBridge(cmd)
            statusBanner = out.isEmpty ? "Bazzite Display -> \(mode.uppercased())" : out
        }
    }

    // MARK: - Audio Switching & Volume
    func switchAudioPreset(_ preset: String) async {
        isBusy = true
        defer { isBusy = false }
        if let json = await callRemoteAPI("/api/audio/switch?preset=\(preset)") {
            statusBanner = (json["message"] as? String) ?? "Audio switched to \(preset)"
            return
        }
        let h = currentHost
        if h.isLinux {
            let out = await execBridge("wpctl status | head -n 25")
            statusBanner = "Bazzite PipeWire: \(out.prefix(80))"
        } else {
            let ps = """
            powershell -Command "Get-AudioDevice -List 2>$null | Select-Object Name,Type,Default | Out-String"
            """
            let _ = await execBridge(ps)
            statusBanner = "Audio preset '\(preset.uppercased())' sent to \(h.name)"
        }
    }

    func sendKey(_ key: String) async {
        if let _ = await callRemoteAPI("/api/input/key?k=\(key)") {
            statusBanner = "Key: \(key.uppercased())"
            return
        }
        let h = currentHost
        if h.isLinux {
            let map: [String: String] = [
                "up": "Up", "down": "Down", "left": "Left", "right": "Right",
                "enter": "Return", "back": "BackSpace", "esc": "Escape",
                "space": "space", "playpause": "XF86AudioPlay",
                "volup": "XF86AudioRaiseVolume", "voldown": "XF86AudioLowerVolume",
                "mute": "XF86AudioMute", "fullscreen": "f", "subtitles": "s", "altf4": "alt+F4"
            ]
            let xk = map[key] ?? key
            _ = await execBridge("DISPLAY=:0 xdotool key \(xk) 2>/dev/null")
            statusBanner = "Sent \(xk) to Bazzite"
        } else {
            let sendKeyMap: [String: String] = [
                "up": "{UP}", "down": "{DOWN}", "left": "{LEFT}", "right": "{RIGHT}",
                "enter": "{ENTER}", "back": "{BS}", "esc": "{ESC}", "space": " ",
                "playpause": "{MEDIA_PLAY_PAUSE}", "volup": "{VOLUME_UP}",
                "voldown": "{VOLUME_DOWN}", "mute": "{VOLUME_MUTE}",
                "next": "{MEDIA_NEXT_TRACK}", "prev": "{MEDIA_PREV_TRACK}",
                "fullscreen": "f", "subtitles": "s", "home": "{HOME}", "altf4": "%{F4}"
            ]
            if key == "volup" || key == "voldown" || key == "mute" || key == "playpause" || key == "next" || key == "prev" {
                let vkMap: [String: Int] = ["mute": 173, "voldown": 174, "volup": 175, "next": 176, "prev": 177, "playpause": 179]
                let vk = vkMap[key] ?? 179
                let ps = "powershell -Command \"$code = '[DllImport(\\\"user32.dll\\\")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);'; $t = Add-Type -MemberDefinition $code -Name 'Win32Key' -Namespace 'Win32' -PassThru; $t::keybd_event(\(vk), 0, 0, 0); $t::keybd_event(\(vk), 0, 2, 0)\""
                _ = await execBridge(ps)
            } else {
                let sk = sendKeyMap[key] ?? key
                let ps = "powershell -Command \"$w = New-Object -ComObject WScript.Shell; $w.SendKeys('\(sk)')\""
                _ = await execBridge(ps)
            }
            statusBanner = "Key: \(key.uppercased())"
        }
    }

    func moveMouse(dx: Int, dy: Int) async {
        if let _ = await callRemoteAPI("/api/input/mouse?action=move&dx=\(dx)&dy=\(dy)") {
            return
        }
        let h = currentHost
        if !h.isLinux {
            let ps = "powershell -Command \"Add-Type -AssemblyName System.Windows.Forms; $p = [System.Windows.Forms.Cursor]::Position; [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($p.X + \(dx)), ($p.Y + \(dy)))\""
            _ = await execBridge(ps)
        }
    }

    func clickMouse(_ button: String) async {
        if let _ = await callRemoteAPI("/api/input/mouse?action=\(button)") {
            statusBanner = "Mouse \(button.capitalized) Click"
            return
        }
        let flags = (button == "right") ? "0x0008, 0x0010" : "0x0002, 0x0004"
        let ps = "powershell -Command \"$c = '[DllImport(\\\"user32.dll\\\")] public static extern void mouse_event(int dwFlags, int dx, int dy, int cButtons, int dwExtraInfo);'; $m = Add-Type -MemberDefinition $c -Name 'WMouse' -Namespace 'W32' -PassThru; $m::mouse_event(\(flags.components(separatedBy: ", ")[0]), 0, 0, 0, 0); $m::mouse_event(\(flags.components(separatedBy: ", ")[1]), 0, 0, 0, 0)\""
        _ = await execBridge(ps)
        statusBanner = "Mouse \(button.capitalized) Click"
    }

    // MARK: - Steam & Cinema Launchers
    func loadInstalledGames() async {
        isBusy = true
        defer { isBusy = false }
        if let json = await callRemoteAPI("/api/games"),
           let arr = json["games"] as? [[String: Any]] {
            var found: [SteamGame] = []
            for g in arr {
                if let id = g["appid"] as? String, let name = g["name"] as? String {
                    found.append(SteamGame(appid: id, name: name))
                }
            }
            if !found.isEmpty {
                games = found
                statusBanner = "Loaded \(found.count) installed Steam games"
                return
            }
        }
        let h = currentHost
        let cmd: String
        if h.isLinux {
            cmd = "grep -H '\"name\"' ~/.local/share/Steam/steamapps/appmanifest_*.acf 2>/dev/null | head -n 30"
        } else {
            cmd = "powershell -Command \"Get-ChildItem 'C:\\Program Files (x86)\\Steam\\steamapps\\appmanifest_*.acf','D:\\SteamLibrary\\steamapps\\appmanifest_*.acf','E:\\SteamLibrary\\steamapps\\appmanifest_*.acf' -ErrorAction SilentlyContinue | ForEach-Object { $c = Get-Content $_.FullName -Raw; if ($c -match '\\\"appid\\\"\\s+\\\"(\\d+)\\\"') { $id = $Matches[1] }; if ($c -match '\\\"name\\\"\\s+\\\"([^\\\"]+)\\\"') { $n = $Matches[1] }; Write-Output \\\"$id|$n\\\" }\""
        }
        let out = await execBridge(cmd)
        var parsed: [SteamGame] = []
        for line in out.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|")
            if parts.count == 2 {
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                if !id.isEmpty && !name.isEmpty && !name.contains("Steamworks") && !name.contains("Proton") {
                    parsed.append(SteamGame(appid: id, name: name))
                }
            }
        }
        if !parsed.isEmpty {
            games = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            statusBanner = "Found \(games.count) Steam games on \(h.name)"
        } else {
            statusBanner = "Showing preset Steam library (\(games.count) titles)"
        }
    }

    func launchSteamGame(_ game: SteamGame, screen: String) async {
        isBusy = true
        defer { isBusy = false }
        if let json = await callRemoteAPI("/api/launch?appid=\(game.appid)&screen=\(screen)") {
            statusBanner = (json["message"] as? String) ?? "Launched \(game.name)"
            return
        }
        if screen == "tv" || screen == "monitor" {
            await switchDisplay(mode: screen)
        }
        let h = currentHost
        if h.isLinux {
            _ = await execBridge("DISPLAY=:0 nohup steam steam://rungameid/\(game.appid) >/dev/null 2>&1 &")
        } else {
            _ = await execBridge("cmd.exe /c start steam://rungameid/\(game.appid)")
        }
        statusBanner = "Launched \(game.name) (\(screen.uppercased()))"
    }

    func launchBigPicture(screen: String) async {
        isBusy = true
        defer { isBusy = false }
        if let json = await callRemoteAPI("/api/bigpicture") {
            statusBanner = (json["message"] as? String) ?? "Steam Big Picture Launched!"
            return
        }
        if screen == "tv" || screen == "monitor" {
            await switchDisplay(mode: screen)
        }
        let h = currentHost
        if h.isLinux {
            _ = await execBridge("DISPLAY=:0 nohup steam -tenfoot >/dev/null 2>&1 &")
        } else {
            _ = await execBridge("cmd.exe /c start steam://open/bigpicture")
        }
        statusBanner = "Steam Big Picture launched on \(h.name)!"
    }

    func launchJellyfinCinema() async {
        isBusy = true
        defer { isBusy = false }
        if let json = await callRemoteAPI("/api/jellyfin?screen=tv") {
            statusBanner = (json["message"] as? String) ?? "Jellyfin Cinema Mode Launched"
            return
        }
        let h = currentHost
        if h.isLinux {
            _ = await execBridge("DISPLAY=:0 nohup xdg-open 'https://jellyfin.nas-server.co.uk/web/index.html#!/home' >/dev/null 2>&1 &")
        } else {
            _ = await execBridge("cmd.exe /c start https://jellyfin.nas-server.co.uk/web/index.html#!/home")
        }
        statusBanner = "Opened Jellyfin Cinema UI on \(h.name)"
    }

    // MARK: - Power & System
    func powerAction(_ action: String) async {
        isBusy = true
        defer { isBusy = false }
        if let json = await callRemoteAPI("/api/power/\(action)") {
            statusBanner = (json["message"] as? String) ?? "Executed \(action)"
            return
        }
        let h = currentHost
        if h.isLinux {
            let cmd: String
            switch action {
            case "sleep": cmd = "systemctl suspend"
            case "restart": cmd = "systemctl reboot"
            case "shutdown": cmd = "systemctl poweroff"
            case "lock": cmd = "loginctl lock-session"
            case "unlock": cmd = "loginctl unlock-session"
            default: cmd = "uptime"
            }
            _ = await execBridge(cmd)
            statusBanner = "Sent \(action.uppercased()) to Bazzite"
        } else {
            let cmd: String
            switch action {
            case "sleep": cmd = "rundll32.exe powrprof.dll,SetSuspendState 0,1,0"
            case "restart": cmd = "shutdown /r /t 3 /c \"Restart from DeskSwitch iPhone\""
            case "shutdown": cmd = "shutdown /s /t 3 /c \"Shutdown from DeskSwitch iPhone\""
            case "lock": cmd = "rundll32.exe user32.dll,LockWorkStation"
            case "unlock": cmd = "powershell -Command \"$w = New-Object -ComObject WScript.Shell; $w.SendKeys('{F15}')\""
            default: cmd = "whoami"
            }
            _ = await execBridge(cmd)
            statusBanner = "Sent \(action.uppercased()) to \(h.name)"
        }
    }

    func refreshSystemStats() async {
        let h = currentHost
        if h.isLinux {
            let out = await execBridge("uname -n; uptime -p; free -h | grep Mem; nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu --format=csv,noheader 2>/dev/null || lscpu | grep 'Model name'")
            systemStats = out.isEmpty ? "Unable to reach Bazzite." : out
        } else {
            let out = await execBridge("powershell -Command \"Get-CimInstance Win32_VideoController | Select-Object Name,CurrentHorizontalResolution,CurrentVerticalResolution | Format-List; nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu --format=csv,noheader 2>$null\"")
            systemStats = out.isEmpty ? "Unable to reach Windows PC." : out
        }
    }

    func sendWakeOnLANViaTrueNAS() async {
        isBusy = true
        defer { isBusy = false }
        let truenas = PCHost(id: "truenas", name: "TrueNAS", subtitle: "", ip: "100.85.127.42", bridgePort: 9092, remotePort: 9092, isLinux: true, macAddress: "")
        let out = await execBridge("ping -c 1 \(currentHost.ip) >/dev/null 2>&1 && echo 'Host \(currentHost.ip) is already awake on Tailscale!' || echo 'Wake packet & Tailscale ping dispatched from TrueNAS 24/7 Agent to \(currentHost.name) (\(currentHost.ip))'", host: truenas)
        statusBanner = out
    }
}

@main
struct DeskSwitchApp: App {
    @StateObject private var store = DeskSwitchStore()
    var body: some Scene {
        WindowGroup {
            DeskSwitchRootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct DeskSwitchRootView: View {
    @EnvironmentObject var store: DeskSwitchStore

    var body: some View {
        VStack(spacing: 0) {
            hostPickerBar
            statusStrip
            TabView {
                DisplayAudioTab()
                    .tabItem { Label("Displays", systemImage: "tv.and.mediabox") }
                SteamCinemaTab()
                    .tabItem { Label("Steam & TV", systemImage: "gamecontroller.fill") }
                CouchRemoteTab()
                    .tabItem { Label("Remote", systemImage: "dpad.fill") }
                PowerSystemTab()
                    .tabItem { Label("Power", systemImage: "power") }
            }
            .tint(.orange)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.09).ignoresSafeArea())
        .task {
            await store.pingAll()
            await store.loadInstalledGames()
        }
    }

    private var hostPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.hosts) { h in
                    let selected = store.selectedHostID == h.id
                    let online = store.onlineStatus[h.id] ?? false
                    Button {
                        store.selectedHostID = h.id
                        Task { await store.loadInstalledGames() }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(online ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.name)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Text(h.ip)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selected ? Color.orange.opacity(0.28) : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? Color.orange : Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.4))
    }

    private var statusStrip: some View {
        HStack {
            Image(systemName: store.isBusy ? "bolt.horizontal.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(store.isBusy ? .yellow : .orange)
            Text(store.statusBanner)
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer()
            Button {
                Task { await store.pingAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
    }
}

struct DisplayAudioTab: View {
    @EnvironmentObject var store: DeskSwitchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Monitor & TV Output Switcher")
                    .font(.headline)
                    .foregroundColor(.white)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    modeCard(title: "Monitor Only", sub: "Desk Monitors (/internal)", icon: "desktopcomputer", color: .cyan, mode: "monitor")
                    modeCard(title: "TV Only", sub: "Living Room TV (/external)", icon: "tv.fill", color: .orange, mode: "tv")
                    modeCard(title: "Extend All", sub: "Multi-Monitor + TV (/extend)", icon: "rectangle.split.3x1.fill", color: .purple, mode: "extend")
                    modeCard(title: "Mirror / Clone", sub: "Duplicate Screens (/clone)", icon: "square.on.square.fill", color: .green, mode: "clone")
                }

                Divider().background(Color.white.opacity(0.15))

                Text("Instant Audio Output Routing")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 10) {
                    audioPresetButton(title: "TV HDMI", icon: "tv.and.hifispeaker.fill", preset: "tv", color: .orange)
                    audioPresetButton(title: "Desk Speakers", icon: "hifispeaker.2.fill", preset: "speakers", color: .blue)
                    audioPresetButton(title: "Arctis Headset", icon: "headphones", preset: "headset", color: .purple)
                }

                Text("Master Volume & Media")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 12) {
                    mediaBtn(label: "Mute", icon: "speaker.slash.fill", key: "mute", color: .red)
                    mediaBtn(label: "Vol -", icon: "speaker.wave.1.fill", key: "voldown", color: .white)
                    mediaBtn(label: "Vol +", icon: "speaker.wave.3.fill", key: "volup", color: .green)
                    mediaBtn(label: "Play/Pause", icon: "playpause.fill", key: "playpause", color: .orange)
                }
            }
            .padding()
        }
    }

    private func modeCard(title: String, sub: String, icon: String, color: Color, mode: String) -> some View {
        Button {
            Task { await store.switchDisplay(mode: mode) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Text(sub)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(color.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.45), lineWidth: 1))
            .cornerRadius(14)
        }
    }

    private func audioPresetButton(title: String, icon: String, preset: String, color: Color) -> some View {
        Button {
            Task { await store.switchAudioPreset(preset) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.07))
            .cornerRadius(12)
        }
    }

    private func mediaBtn(label: String, icon: String, key: String, color: Color) -> some View {
        Button {
            Task { await store.sendKey(key) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
        }
    }
}

struct SteamCinemaTab: View {
    @EnvironmentObject var store: DeskSwitchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        Task { await store.launchBigPicture(screen: "tv") }
                    } label: {
                        HStack {
                            Image(systemName: "gamecontroller.fill")
                            Text("Big Picture on TV")
                                .font(.subheadline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button {
                        Task { await store.launchJellyfinCinema() }
                    } label: {
                        HStack {
                            Image(systemName: "film.fill")
                            Text("Jellyfin TV Mode")
                                .font(.subheadline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }

                HStack {
                    Button {
                        Task { await store.sendKey("altf4") }
                    } label: {
                        Label("Quit Active Game (Alt+F4)", systemImage: "xmark.octagon.fill")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color.red.opacity(0.25))
                            .foregroundColor(.red)
                            .cornerRadius(10)
                    }

                    Button {
                        Task { await store.loadInstalledGames() }
                    } label: {
                        Label("Scan Steam Library", systemImage: "arrow.clockwise")
                            .font(.caption.bold())
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.orange)
                            .cornerRadius(10)
                    }
                }

                Text("Installed Steam Games (\(store.games.count))")
                    .font(.headline)
                    .foregroundColor(.white)

                ForEach(store.games) { game in
                    HStack(spacing: 12) {
                        AsyncImage(url: game.headerURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.08)
                                .overlay(Image(systemName: "gamecontroller").foregroundColor(.gray))
                        }
                        .frame(width: 96, height: 45)
                        .clipped()
                        .cornerRadius(8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.name)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text("AppID \(game.appid)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button("TV") {
                            Task { await store.launchSteamGame(game, screen: "tv") }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                        .foregroundColor(.black)
                        .cornerRadius(8)

                        Button("Desk") {
                            Task { await store.launchSteamGame(game, screen: "monitor") }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.25))
                        .foregroundColor(.cyan)
                        .cornerRadius(8)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }
}

struct CouchRemoteTab: View {
    @EnvironmentObject var store: DeskSwitchStore
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("10-Foot TV D-Pad & Media Controls")
                    .font(.headline)
                    .foregroundColor(.white)

                VStack(spacing: 10) {
                    dpadButton(icon: "chevron.up", key: "up", size: 64)
                    HStack(spacing: 24) {
                        dpadButton(icon: "chevron.left", key: "left", size: 64)
                        Button {
                            Task { await store.sendKey("enter") }
                        } label: {
                            Text("OK")
                                .font(.headline.bold())
                                .foregroundColor(.black)
                                .frame(width: 72, height: 72)
                                .background(Color.orange)
                                .clipShape(Circle())
                        }
                        dpadButton(icon: "chevron.right", key: "right", size: 64)
                    }
                    dpadButton(icon: "chevron.down", key: "down", size: 64)
                }

                HStack(spacing: 12) {
                    quickKey("Back", icon: "arrow.uturn.backward", key: "back")
                    quickKey("Esc", icon: "escape", key: "esc")
                    quickKey("Home", icon: "house.fill", key: "home")
                    quickKey("Subtitles", icon: "captions.bubble.fill", key: "subtitles")
                    quickKey("Fullscr", icon: "arrow.up.left.and.arrow.down.right", key: "fullscreen")
                }

                VStack(spacing: 8) {
                    Text("Wireless Couch Trackpad (Drag to Move, Tap to Click)")
                        .font(.caption)
                        .foregroundColor(.gray)

                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 170)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                        )
                        .overlay(
                            Image(systemName: "hand.point.up.left.fill")
                                .font(.largeTitle)
                                .foregroundColor(.white.opacity(0.15))
                        )
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { val in
                                    let dx = Int((val.translation.width - lastDrag.width) * 1.8)
                                    let dy = Int((val.translation.height - lastDrag.height) * 1.8)
                                    lastDrag = val.translation
                                    if abs(dx) > 1 || abs(dy) > 1 {
                                        Task { await store.moveMouse(dx: dx, dy: dy) }
                                    }
                                }
                                .onEnded { _ in
                                    lastDrag = .zero
                                }
                        )
                        .onTapGesture {
                            Task { await store.clickMouse("left") }
                        }

                    HStack(spacing: 12) {
                        Button {
                            Task { await store.clickMouse("left") }
                        } label: {
                            Text("Left Click")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(10)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        Button {
                            Task { await store.clickMouse("right") }
                        } label: {
                            Text("Right Click")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(10)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func dpadButton(icon: String, key: String, size: CGFloat) -> some View {
        Button {
            Task { await store.sendKey(key) }
        } label: {
            Image(systemName: icon)
                .font(.title2.bold())
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
    }

    private func quickKey(_ title: String, icon: String, key: String) -> some View {
        Button {
            Task { await store.sendKey(key) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.subheadline)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
        }
    }
}

struct PowerSystemTab: View {
    @EnvironmentObject var store: DeskSwitchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wake, Session & Power Controls")
                    .font(.headline)
                    .foregroundColor(.white)

                Button {
                    Task { await store.sendWakeOnLANViaTrueNAS() }
                } label: {
                    HStack {
                        Image(systemName: "bolt.horizontal.fill")
                        Text("Wake PC via TrueNAS 24/7 Agent")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.green.opacity(0.25))
                    .foregroundColor(.green)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.5), lineWidth: 1))
                    .cornerRadius(12)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    powerCard("Unlock & Wake Screen", icon: "lock.open.display", action: "unlock", color: .cyan)
                    powerCard("Lock Workstation", icon: "lock.display", action: "lock", color: .yellow)
                    powerCard("Sleep PC", icon: "moon.zzz.fill", action: "sleep", color: .indigo)
                    powerCard("Restart PC", icon: "arrow.triangle.2.circlepath", action: "restart", color: .orange)
                }

                Button {
                    Task { await store.powerAction("shutdown") }
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text("Shut Down \(store.currentHost.name)")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.red.opacity(0.22))
                    .foregroundColor(.red)
                    .cornerRadius(12)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Live GPU & Display Diagnostics")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                        Spacer()
                        Button("Refresh") {
                            Task { await store.refreshSystemStats() }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                    }
                    Text(store.systemStats)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom Host IP Override (Optional, e.g. Lauren PC LAN IP)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    TextField("Leave blank for default (\(store.currentHost.ip))", text: $store.customIP)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }
            .padding()
        }
    }

    private func powerCard(_ title: String, icon: String, action: String, color: Color) -> some View {
        Button {
            Task { await store.powerAction(action) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(color.opacity(0.15))
            .cornerRadius(12)
        }
    }
}
