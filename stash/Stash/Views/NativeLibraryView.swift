import AVKit
import SwiftUI

struct NativeVideoPlayerSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.entersFullScreenWhenPlaybackBegins = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

struct NativeLibraryView: View {
    @EnvironmentObject private var store: StashStore
    @State private var mode: Int = 0 // 0 = Scenes, 1 = Images
    @State private var searchText: String = ""
    @State private var playingScene: StashSceneItem?
    @State private var viewingImage: StashImageItem?
    @State private var actionNotice: String?

    private let sceneColumns = [
        GridItem(.adaptive(minimum: 160), spacing: 12)
    ]
    private let imageColumns = [
        GridItem(.adaptive(minimum: 115), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsBar

                    Picker("Media Type", selection: $mode) {
                        Text("Scenes (\(store.stats.sceneCount))").tag(0)
                        Text("Images (\(store.stats.imageCount))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if let notice = actionNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(StashTheme.success)
                            Text(notice)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(StashTheme.textPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StashTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }

                    if mode == 0 {
                        scenesGrid
                    } else {
                        imagesGrid
                    }
                }
                .padding(.vertical, 12)
            }
            .background(StashTheme.background)
            .navigationTitle("Native Player")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search scenes & images…")
            .onSubmit(of: .search) {
                Task { await store.refreshAll(searchQuery: searchText) }
            }
            .onChange(of: searchText) { newValue in
                if newValue.isEmpty {
                    Task { await store.refreshAll(searchQuery: "") }
                }
            }
            .refreshable {
                await store.refreshAll(searchQuery: searchText)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            actionNotice = await store.triggerScan()
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            await store.refreshAll(searchQuery: searchText)
                        }
                    } label: {
                        Label("Scan IDrive-Sync", systemImage: "folder.badge.gearshape")
                    }
                }
            }
            .task {
                await store.refreshAll(searchQuery: searchText)
            }
            .sheet(item: $playingScene) { scene in
                if let url = scene.streamURL {
                    NativeVideoPlayerSheet(url: url)
                        .ignoresSafeArea()
                }
            }
            .sheet(item: $viewingImage) { img in
                FullScreenImageSheet(item: img)
            }
        }
    }

    private var statsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                statChip(title: "Scenes", value: store.stats.sceneCount, symbol: "film.stack.fill")
                statChip(title: "Images", value: store.stats.imageCount, symbol: "photo.fill")
                statChip(title: "Galleries", value: store.stats.galleryCount, symbol: "rectangle.stack.fill")
                statChip(title: "Performers", value: store.stats.performerCount, symbol: "person.2.fill")
                statChip(title: "Tags", value: store.stats.tagCount, symbol: "tag.fill")
            }
            .padding(.horizontal, 16)
        }
    }

    private func statChip(title: String, value: Int, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StashTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(StashTheme.textPrimary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(StashTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StashTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StashTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var scenesGrid: some View {
        if store.scenes.isEmpty {
            emptyState(
                title: "No Scenes Indexed Yet",
                subtitle: "Tap 'Scan IDrive-Sync' in the top right (or complete initial setup in the Web UI tab) to index videos from /data/IDrive-Sync."
            )
        } else {
            LazyVGrid(columns: sceneColumns, spacing: 12) {
                ForEach(store.scenes) { scene in
                    Button {
                        playingScene = scene
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                AsyncImage(url: scene.screenshotURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        Rectangle()
                                            .fill(StashTheme.card)
                                            .overlay {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 28))
                                                    .foregroundStyle(StashTheme.accent.opacity(0.8))
                                            }
                                    }
                                }
                                .frame(height: 105)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                if scene.duration > 0 {
                                    Text(Self.formatDuration(scene.duration))
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                                        .padding(6)
                                }
                            }

                            Text(scene.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StashTheme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if let studio = scene.studioName, !studio.isEmpty {
                                Text(studio)
                                    .font(.system(size: 11))
                                    .foregroundStyle(StashTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .background(StashTheme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StashTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var imagesGrid: some View {
        if store.images.isEmpty {
            emptyState(
                title: "No Images Indexed Yet",
                subtitle: "Tap 'Scan IDrive-Sync' in the top right (or enable Images in your Stash library settings) to browse photos."
            )
        } else {
            LazyVGrid(columns: imageColumns, spacing: 8) {
                ForEach(store.images) { item in
                    Button {
                        viewingImage = item
                    } label: {
                        AsyncImage(url: item.thumbnailURL ?? item.imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Rectangle()
                                    .fill(StashTheme.card)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .foregroundStyle(StashTheme.textSecondary)
                                    }
                            }
                        }
                        .frame(height: 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StashTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(StashTheme.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(StashTheme.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(StashTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    actionNotice = await store.triggerScan()
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await store.refreshAll(searchQuery: searchText)
                }
            } label: {
                Label("Scan /data/IDrive-Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(StashTheme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(StashTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StashTheme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

struct FullScreenImageSheet: View {
    let item: StashImageItem
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: item.imageURL ?? item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in scale = max(1.0, min(value, 5.0)) }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation { scale = scale > 1.0 ? 1.0 : 2.5 }
                            }
                    case .failure:
                        Text("Failed to load image")
                            .foregroundStyle(.white)
                    default:
                        ProgressView().tint(.white)
                    }
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
