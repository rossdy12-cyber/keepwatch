import SwiftUI

// MARK: - Car Driving Mode & Offline Music Cache Sheet (#9)

struct CarDrivingModeSheet: View {
    @ObservedObject var music = MusicPlayer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let art = music.artwork {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 210, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(radius: 16)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Theme.surface)
                            .frame(width: 210, height: 210)
                        Image(systemName: "car.fill")
                            .font(.system(size: 68))
                            .foregroundStyle(Theme.jarvisBlue)
                    }
                }

                VStack(spacing: 6) {
                    Text(music.current?.displayTitle ?? "No Track Playing")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(music.current?.artist ?? "Navidrome Car Mode")
                        .font(.headline)
                        .foregroundStyle(Theme.secondaryText)
                    if let current = music.current, music.isCached(current) {
                        Label("PLAYING FROM OFFLINE CACHE", systemImage: "arrow.down.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.good)
                    }
                }
                .padding(.horizontal, 20)

                // Giant Car-Friendly Controls
                HStack(spacing: 28) {
                    Button {
                        music.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 36, weight: .bold))
                            .frame(width: 86, height: 86)
                            .background(Theme.surface, in: Circle())
                    }

                    Button {
                        music.togglePlayPause()
                    } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 104, height: 104)
                            .background(Theme.jarvisBlue, in: Circle())
                    }

                    Button {
                        music.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 36, weight: .bold))
                            .frame(width: 86, height: 86)
                            .background(Theme.surface, in: Circle())
                    }
                }
                .buttonStyle(.plain)

                // Offline Caching Controls
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Offline Music Vault (\(music.cachedSongs.count) tracks)", systemImage: "internaldrive.fill")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            if music.cachingInProgress {
                                ProgressView()
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                Task { await music.cacheCurrentQueue() }
                            } label: {
                                Label(music.cachingInProgress ? "Downloading…" : "Cache Queue Offline",
                                      systemImage: "arrow.down.to.line.circle.fill")
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(music.cachingInProgress || music.queue.isEmpty)

                            Button {
                                music.playCachedOffline()
                            } label: {
                                Label("Play Offline Tracks", systemImage: "play.circle.fill")
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.good)
                            .disabled(music.cachedSongs.isEmpty)
                        }

                        if !music.cachedSongs.isEmpty {
                            Button(role: .destructive) {
                                music.clearOfflineCache()
                            } label: {
                                Label("Clear Offline Music Cache", systemImage: "trash")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)

                Spacer()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Car & Offline Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Jarvis Smart Alarms, House Broadcast & Desktop GPU / RunPod Sheet (#8 & #12)

struct JarvisControlSheet: View {
    @EnvironmentObject private var bridge: HomelabBridgeStore
    @Environment(\.dismiss) private var dismiss

    @State private var broadcastMessage = ""
    @State private var alarmTime = "07:00"
    @State private var alarmLabel = "Morning Wake-Up & Briefing"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = bridge.statusBanner {
                        statusToast(banner)
                    }

                    // 1. Desktop PC / Ollama GPU & RunPod Controller (#12)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Desktop Rig & GPU Brain", systemImage: "desktopcomputer")
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(bridge.desktopOllamaOnline ? Theme.good : Theme.warning)
                                        .frame(width: 8, height: 8)
                                    Text(bridge.desktopOllamaOnline ? "Desktop GPU Online" : "NAS CPU Fallback")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(bridge.desktopOllamaOnline ? Theme.good : Theme.warning)
                                }
                            }

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                pcActionBtn("Wake PC (WoL)", icon: "power", prompt: "Wake up my desktop PC")
                                pcActionBtn("Sleep PC", icon: "moon.zzz.fill", prompt: "Put my desktop PC to sleep")
                                pcActionBtn("Quiet Fans", icon: "fanblades", prompt: "Set PC fans to quiet mode")
                                pcActionBtn("Max Cooling", icon: "wind", prompt: "Set PC fans to max cooling")
                            }

                            Button {
                                Task { await bridge.sendPCCommand("Sync RunPod S3 storage now") }
                            } label: {
                                Label("Trigger RunPod S3 Cloud Sync", systemImage: "cloud.bolt.fill")
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.jarvisBlue)
                        }
                    }

                    // 2. House Speaker Broadcast (Pi / Kokoro / Echo) (#8)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "House Speaker Broadcast", symbol: "megaphone.fill")
                            Text("Speak an instant announcement over your Raspberry Pi / Kokoro voice hub and Jarvis intercom.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)

                            HStack(spacing: 8) {
                                TextField("e.g. Dinner is ready downstairs!", text: $broadcastMessage)
                                    .padding(10)
                                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))

                                Button {
                                    let msg = broadcastMessage
                                    broadcastMessage = ""
                                    Task { await bridge.broadcastToHouse(message: msg) }
                                } label: {
                                    Label("Announce", systemImage: "speaker.wave.3.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.jarvisBlue)
                                .disabled(broadcastMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }

                    // 3. Jarvis Smart Alarms (#8)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "Jarvis Smart Alarms", symbol: "alarm.fill")

                            HStack(spacing: 8) {
                                TextField("07:00", text: $alarmTime)
                                    .frame(width: 80)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))

                                TextField("Alarm label", text: $alarmLabel)
                                    .padding(10)
                                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))

                                Button {
                                    Task {
                                        await bridge.addAlarm(time: alarmTime, label: alarmLabel)
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(Theme.good)
                                }
                            }

                            if bridge.alarms.isEmpty {
                                Text("No active Jarvis alarms.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            } else {
                                ForEach(bridge.alarms) { alarm in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(alarm.time)
                                                .font(.title3.monospacedDigit().weight(.bold))
                                                .foregroundStyle(Theme.jarvisBlue)
                                            Text(alarm.label)
                                                .font(.caption)
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                        Spacer()
                                        Button(role: .destructive) {
                                            Task { await bridge.deleteAlarm(id: alarm.id) }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                    }
                                    Divider().overlay(Theme.border)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("PC, Alarms & Intercom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await bridge.loadSystemBridge() }
        }
    }

    private func pcActionBtn(_ label: String, icon: String, prompt: String) -> some View {
        Button {
            Task { await bridge.sendPCCommand(prompt) }
        } label: {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.jarvisBlue)
    }
}
