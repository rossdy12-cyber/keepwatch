import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var settings: FrigateSettings
    @EnvironmentObject private var store: FrigateStore
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var fullCamera: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if !settings.isConfigured {
                    ConfigurePrompt()
                } else {
                    ScrollView {
                        if let status = store.status {
                            Label(status, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(Theme.warning)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        }
                        if !settings.agentURL.isEmpty { patrolCard }
                        if store.cameras.isEmpty && !store.loading {
                            Text("No cameras found.").foregroundStyle(Theme.secondaryText).padding(.top, 40)
                        }
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.cameras, id: \.self) { cam in
                                LiveSnapshot(client: settings.client, camera: cam)
                                    .aspectRatio(16.0/9.0, contentMode: .fill)
                                    .frame(minHeight: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottomLeading) {
                                        Text(cam.prettyCamera)
                                            .font(.caption2.bold()).foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(.black.opacity(0.55), in: Capsule())
                                            .padding(6)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { fullCamera = cam }
                            }
                        }
                        .padding(10)
                    }
                    .refreshable { await store.start(settings) }
                }
            }
            .navigationTitle("Live")
            .background(Theme.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { if store.loading { ProgressView() } } }
            .fullScreenCover(isPresented: Binding(get: { fullCamera != nil }, set: { if !$0 { fullCamera = nil } })) {
                if let cam = fullCamera {
                    FullScreenCamera(client: settings.client, camera: cam) { fullCamera = nil }
                }
            }
            .onChange(of: router.camera) { cam in
                if let cam { fullCamera = cam; router.camera = nil }
            }
        }
    }

    private var patrolCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tapo Patrol", systemImage: "dial.medium.fill").font(.subheadline.bold())
            if let patrol = store.patrol {
                Text(patrol).font(.caption).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button("Resume") { Task { await store.runPatrol(settings, command: "docker start tapo-patrol && echo Resumed", label: "Resuming") } }
                    .buttonStyle(.borderedProminent).tint(Theme.good)
                Button("Pause") { Task { await store.runPatrol(settings, command: "docker stop tapo-patrol && echo Paused", label: "Pausing") } }
                    .buttonStyle(.bordered).tint(Theme.warning)
                Button("Logs") { Task { await store.runPatrol(settings, command: "docker logs --tail 5 tapo-patrol 2>&1", label: "Fetching logs") } }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
        }
        .padding()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
    }
}

struct FullScreenCamera: View {
    let client: FrigateClient
    let camera: String
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            LiveSnapshot(client: client, camera: camera).ignoresSafeArea()
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
                    .padding()
            }
        }
        .statusBarHidden()
    }
}
