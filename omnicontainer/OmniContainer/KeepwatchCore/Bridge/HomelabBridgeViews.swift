import SwiftUI

// MARK: - 1. Full Docker Container Deck (#11)

struct DockerDeckView: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore
    @State private var search = ""
    @State private var selectedLogContainer: String?
    @State private var logText = "Loading logs…"

    private var filtered: [DockerContainerInfo] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return bridge.containers }
        return bridge.containers.filter {
            $0.name.lowercased().contains(q) || $0.image.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = bridge.statusBanner {
                        statusToast(banner)
                    }

                    HStack(spacing: 12) {
                        let running = bridge.containers.filter(\.isRunning).count
                        Label("\(running) Running", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.good)
                        Label("\(bridge.containers.count - running) Stopped", systemImage: "stop.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    ForEach(filtered) { c in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Circle()
                                        .fill(c.isRunning ? Theme.good : Theme.warning)
                                        .frame(width: 9, height: 9)
                                    Text(c.name)
                                        .font(.subheadline.weight(.bold))
                                    Spacer()
                                    Text(c.status)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                }

                                Text(c.image)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)

                                if !c.ports.isEmpty {
                                    Text(c.ports)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.accent)
                                        .lineLimit(1)
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        Task {
                                            await bridge.containerAction(
                                                name: c.name,
                                                action: c.isRunning ? "restart" : "start"
                                            )
                                        }
                                    } label: {
                                        Label(c.isRunning ? "Restart" : "Start",
                                              systemImage: c.isRunning ? "arrow.clockwise" : "play.fill")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.accent)

                                    if c.isRunning {
                                        Button(role: .destructive) {
                                            Task { await bridge.containerAction(name: c.name, action: "stop") }
                                        } label: {
                                            Label("Stop", systemImage: "stop.fill")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Spacer()

                                    Button {
                                        selectedLogContainer = c.name
                                        logText = "Loading logs for \(c.name)…"
                                        Task {
                                            logText = await bridge.fetchContainerLogs(name: c.name)
                                        }
                                    } label: {
                                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .searchable(text: $search, prompt: "Filter containers (frigate, slskd, authelia…)")
            .navigationTitle("Docker Deck")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await bridge.loadContainers() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .keepwatchChrome()
            .task { await bridge.loadContainers() }
            .refreshable { await bridge.loadContainers() }
            .sheet(isPresented: Binding(
                get: { selectedLogContainer != nil },
                set: { if !$0 { selectedLogContainer = nil } }
            )) {
                NavigationStack {
                    ScrollView {
                        Text(logText)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .background(Theme.background.ignoresSafeArea())
                    .navigationTitle(selectedLogContainer ?? "Logs")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedLogContainer = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                UIPasteboard.general.string = logText
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 2. Frigate Cameras, Tapo Patrol & Smart Doorbell (#2 & #13)

struct CamerasPatrolView: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = bridge.statusBanner {
                        statusToast(banner)
                    }

                    // Quick Security Controls (Tapo Patrol, Home/Away Alert Mute, Reconnect Doorbell)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "Security & Doorbell Controls", symbol: "shield.lefthalf.filled")
                            HStack(spacing: 8) {
                                Button {
                                    Task { await bridge.cameraAction("toggle_patrol") }
                                } label: {
                                    Label(
                                        bridge.patrolRunning ? "Patrol: ON" : "Patrol: OFF",
                                        systemImage: bridge.patrolRunning ? "video.badge.checkmark" : "video.slash"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(bridge.patrolRunning ? Theme.good : Theme.elevated)

                                Button {
                                    Task { await bridge.cameraAction("toggle_alerts") }
                                } label: {
                                    Label(
                                        bridge.alertsEnabled ? "Away (Alerts ON)" : "Home (Muted)",
                                        systemImage: bridge.alertsEnabled ? "bell.badge.fill" : "bell.slash.fill"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(bridge.alertsEnabled ? Theme.accent : Theme.warning)
                            }

                            Button {
                                Task { await bridge.cameraAction("reconnect_doorbell") }
                            } label: {
                                Label("Reconnect Android Front Doorbell Bridge", systemImage: "bell.and.waves.left.and.right.fill")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.jarvisBlue)
                        }
                    }

                    // Live Camera Snapshots
                    ForEach(bridge.cameras) { cam in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(cam.name, systemImage: "video.fill")
                                        .font(.subheadline.weight(.bold))
                                    Spacer()
                                    Text("LIVE SNAPSHOT")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Theme.good)
                                }

                                if let url = bridge.snapshotURL(for: cam.id) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(16 / 9, contentMode: .fill)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        case .failure:
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 10).fill(Theme.elevated)
                                                Label("Camera offline or refreshing", systemImage: "video.slash")
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.secondaryText)
                                            }
                                            .frame(height: 170)
                                        default:
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 10).fill(Theme.elevated)
                                                ProgressView()
                                            }
                                            .frame(height: 170)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Frigate Detection Events & Doorbell Feed
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "Recent Detections & Doorbell Events", symbol: "figure.walk.motion")
                            if bridge.cameraEvents.isEmpty {
                                Text("No recent motion or person events.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            } else {
                                ForEach(bridge.cameraEvents) { ev in
                                    HStack(spacing: 12) {
                                        if let thumb = bridge.eventThumbnailURL(for: ev.id) {
                                            AsyncImage(url: thumb) { phase in
                                                if case .success(let img) = phase {
                                                    img.resizable().scaledToFill()
                                                } else {
                                                    Color.gray.opacity(0.2)
                                                }
                                            }
                                            .frame(width: 64, height: 42)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(ev.label.capitalized) (\(ev.score)%)")
                                                .font(.subheadline.weight(.semibold))
                                            Text(ev.camera)
                                                .font(.caption)
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                        Spacer()
                                        Text(ev.formattedTime)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                    Divider().overlay(Theme.border)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Cameras & Doorbell")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await bridge.loadCameras() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .keepwatchChrome()
            .task { await bridge.loadCameras() }
            .refreshable { await bridge.loadCameras() }
        }
    }
}

// MARK: - 3. "Drop-to-NAS" Universal Media Grabber (#1)

struct DropToNASView: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore
    @State private var input = ""
    @State private var selectedTarget = "auto"
    @State private var sending = false

    private let targets: [(id: String, label: String, icon: String)] = [
        ("auto", "Auto-Detect (Smart Router)", "sparkles"),
        ("metube-video", "MeTube / yt-dlp (Best Video)", "film"),
        ("metube-audio", "MeTube / yt-dlp (Audio MP3)", "music.note"),
        ("gallery-dl", "gallery-dl (Image Gallery)", "photo.on.rectangle.angled"),
        ("mega", "Mega.nz Downloader", "icloud.and.arrow.down"),
        ("slskd", "Soulseek (slskd + Soularr Music)", "waveform.badge.magnifyingglass")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = bridge.statusBanner {
                        statusToast(banner)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(title: "Drop Link or Search to NAS", symbol: "tray.and.arrow.down.fill")
                            Text("Paste a YouTube, TikTok, Instagram, Reddit, Mega, or gallery URL — or type an artist/album to grab on Soulseek.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)

                            HStack(spacing: 8) {
                                TextField("https://… or Artist - Album", text: $input)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(10)
                                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))

                                Button {
                                    if let clip = UIPasteboard.general.string {
                                        input = clip
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .padding(10)
                                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }

                            Picker("Downloader", selection: $selectedTarget) {
                                ForEach(targets, id: \.id) { t in
                                    Label(t.label, systemImage: t.icon).tag(t.id)
                                }
                            }
                            .pickerStyle(.menu)

                            HStack(spacing: 10) {
                                Button {
                                    Task {
                                        sending = true
                                        _ = await bridge.dropToNAS(urlOrQuery: input, target: selectedTarget)
                                        input = ""
                                        sending = false
                                    }
                                } label: {
                                    HStack {
                                        if sending { ProgressView().tint(.black) }
                                        Label("Send to NAS", systemImage: "paperplane.fill")
                                            .font(.subheadline.weight(.bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button {
                                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                        input = clip
                                        Task {
                                            sending = true
                                            _ = await bridge.dropToNAS(urlOrQuery: clip, target: selectedTarget)
                                            sending = false
                                        }
                                    }
                                } label: {
                                    Label("1-Tap Paste & Send", systemImage: "bolt.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.good)
                            }
                        }
                    }

                    if !bridge.dropHistory.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(title: "Recent Drops", symbol: "clock.arrow.circlepath")
                                ForEach(bridge.dropHistory) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.target.uppercased())
                                                .font(.caption2.weight(.bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Theme.accent.opacity(0.2), in: Capsule())
                                                .foregroundStyle(Theme.accent)
                                            Spacer()
                                            Text(item.timestamp, style: .time)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                        Text(item.query)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                        Text(item.message)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.good)
                                    }
                                    Divider().overlay(Theme.border)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Drop to NAS")
            .keepwatchChrome()
        }
    }
}

// MARK: - 4. Jellyseerr Discover & Tdarr Pipeline (#5)

struct MediaPipelineView: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = bridge.statusBanner {
                        statusToast(banner)
                    }

                    // Tdarr Transcoding Control Card
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Tdarr Transcoding Server", systemImage: "cpu.fill")
                                    .font(.subheadline.weight(.bold))
                                Text(bridge.tdarrRunning ? "Workers active & transcoding library" : "Paused (Full CPU/GPU free)")
                                    .font(.caption)
                                    .foregroundStyle(bridge.tdarrRunning ? Theme.good : Theme.warning)
                            }
                            Spacer()
                            Button {
                                Task { await bridge.toggleTdarr() }
                            } label: {
                                Text(bridge.tdarrRunning ? "Pause Tdarr" : "Start Tdarr")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(bridge.tdarrRunning ? Theme.warning : Theme.good)
                        }
                    }

                    // Jellyseerr Search & Trending
                    HStack(spacing: 8) {
                        TextField("Search Movies or TV in Jellyseerr…", text: $query)
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .onSubmit {
                                Task { await bridge.loadMediaPipeline(query: query) }
                            }
                        Button {
                            Task { await bridge.loadMediaPipeline(query: query) }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .padding(10)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.black)
                        }
                    }

                    ForEach(bridge.discoverItems) { item in
                        Card {
                            HStack(alignment: .top, spacing: 12) {
                                if !item.poster.isEmpty, let url = URL(string: item.poster) {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFill()
                                        } else {
                                            Color.gray.opacity(0.2)
                                        }
                                    }
                                    .frame(width: 64, height: 94)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.title)
                                            .font(.subheadline.weight(.bold))
                                        if !item.year.isEmpty {
                                            Text("(\(item.year))")
                                                .font(.caption)
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                        Spacer()
                                        Text(item.mediaType.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Text(item.overview)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(3)
                                    HStack {
                                        Spacer()
                                        Button {
                                            Task { await bridge.requestJellyseerr(item: item) }
                                        } label: {
                                            Label(item.statusLabel, systemImage: item.status >= 2 ? "checkmark.circle.fill" : "plus.circle.fill")
                                                .font(.caption.weight(.bold))
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(item.status >= 2 ? Theme.good : Theme.accent)
                                        .disabled(item.status >= 2)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Jellyseerr & Tdarr")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await bridge.loadMediaPipeline(query: query) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .keepwatchChrome()
            .task { await bridge.loadMediaPipeline() }
            .refreshable { await bridge.loadMediaPipeline(query: query) }
        }
    }
}

// MARK: - 5. Apple Re-Auth (iCloudPD & AltServer) & Immich Face Albums (#3 & #14 without iDrive)

struct AppleWatchdogView: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore
    @State private var twoFactorCode = ""
    @State private var targetContainer = "icloudpd"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = bridge.statusBanner {
                        statusToast(banner)
                    }

                    // 1-Tap iCloudPD 2FA Re-Auth Card
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "iCloudPD 2FA Re-Auth Companion", symbol: "key.icloud.fill")
                            Text("When Apple expires your iCloud session cookie, enter the 6-digit Apple verification code here to re-authenticate without SSH.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)

                            Picker("iCloud Container", selection: $targetContainer) {
                                Text("icloudpd (Main)").tag("icloudpd")
                                Text("icloudpd-hidden").tag("icloudpd-hidden")
                                Text("icloudpd-shared").tag("icloudpd-shared")
                            }
                            .pickerStyle(.segmented)

                            HStack(spacing: 8) {
                                TextField("6-digit Apple 2FA code", text: $twoFactorCode)
                                    .keyboardType(.numberPad)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))

                                Button {
                                    let code = twoFactorCode
                                    twoFactorCode = ""
                                    Task {
                                        await bridge.appleServiceAction(
                                            action: "submit_2fa",
                                            container: targetContainer,
                                            code: code
                                        )
                                    }
                                } label: {
                                    Text("Submit 2FA")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .disabled(twoFactorCode.trimmingCharacters(in: .whitespaces).count < 6)
                            }
                        }
                    }

                    // Immich Ross & Lauren Face Clustering Card
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Immich Face Albums (Ross & Lauren)", systemImage: "person.2.crop.square.stack.fill")
                                    .font(.subheadline.weight(.bold))
                                Text("Sync face-recognition albums (album-ross & album-ross-and-lauren)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button {
                                Task { await bridge.appleServiceAction(action: "refresh_faces") }
                            } label: {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.gothicPurple)
                        }
                    }

                    // Live Status of iCloudPD, AltServer, Anisette & Immich Face Containers
                    ForEach(bridge.appleServices) { svc in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle()
                                        .fill(svc.needs2FA ? Theme.danger : (svc.state == "running" ? Theme.good : Theme.warning))
                                        .frame(width: 9, height: 9)
                                    Text(svc.displayName)
                                        .font(.subheadline.weight(.bold))
                                    Spacer()
                                    Text(svc.needs2FA ? "NEEDS 2FA" : svc.status)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(svc.needs2FA ? Theme.danger : Theme.secondaryText)
                                }
                                if !svc.lastLog.isEmpty {
                                    Text(svc.lastLog)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(2)
                                }
                                HStack {
                                    Spacer()
                                    Button {
                                        Task {
                                            await bridge.appleServiceAction(action: "restart", container: svc.name)
                                        }
                                    } label: {
                                        Label("Restart / Sync", systemImage: "arrow.clockwise")
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("iCloud, AltServer & Immich")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await bridge.loadAppleServices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .keepwatchChrome()
            .task { await bridge.loadAppleServices() }
            .refreshable { await bridge.loadAppleServices() }
        }
    }
}

@ViewBuilder
func statusToast(_ message: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "info.circle.fill")
            .foregroundStyle(Theme.accent)
        Text(message)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
        Spacer()
    }
    .padding(10)
    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
}
