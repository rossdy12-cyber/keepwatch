import SwiftUI
import AVKit

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let items: [VaultItem]
    @State private var selection: String

    init(item: VaultItem, items: [VaultItem]) {
        let media = items.filter { !$0.isDirectory && ($0.isImage || $0.isVideo) }
        self.items = media.contains(where: { $0.id == item.id }) ? media : [item]
        _selection = State(initialValue: item.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                TabView(selection: $selection) {
                    ForEach(items) { item in
                        MediaPage(item: item, isActive: selection == item.id,
                                  size: geometry.size)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
            }
            .accessibilityLabel("Close viewer")
        }
        .overlay(alignment: .bottom) {
            if let index = items.firstIndex(where: { $0.id == selection }) {
                Text("\(index + 1) / \(items.count)")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct MediaPage: View {
    @EnvironmentObject private var vault: VaultModel
    let item: VaultItem
    let isActive: Bool
    let size: CGSize
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black
            if item.isVideo {
                if let player {
                    VideoPlayer(player: player)
                        .frame(width: size.width, height: size.height)
                } else if isLoading {
                    ProgressView("Preparing video…").tint(.white)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.white).padding()
                }
            } else if isActive {
                AuthenticatedImage(item: item, contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: isActive) {
            guard item.isVideo else { return }
            if isActive { await loadVideo() } else { cleanup() }
        }
        .onChange(of: isActive) { _, active in
            if !active { cleanup() }
        }
        .onDisappear { cleanup() }
    }

    @MainActor
    private func loadVideo() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await vault.download(item)
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(item.fileExtension)
            try data.write(to: url)
            temporaryURL = url
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func cleanup() {
        player?.pause()
        player = nil
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
    }
}

struct AuthenticatedImage: View {
    @EnvironmentObject private var vault: VaultModel
    let item: VaultItem
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height,
                               alignment: .center)
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .center)
            .clipped()
        }
        .task(id: item.id) { await load() }
    }

    @MainActor
    private func load() async {
        guard image == nil else { return }
        failed = false
        guard let request = vault.request(for: item) else {
            failed = true
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            image = decoded
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
