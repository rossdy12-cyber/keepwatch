import SwiftUI
import AVKit

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vault: VaultModel

    let item: VaultItem

    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if item.isVideo {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else if isLoading {
                    ProgressView("Preparing video…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Cannot play video",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                }
            } else {
                AuthenticatedImage(item: item)
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .task {
            if item.isVideo {
                await loadVideo()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadVideo() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await vault.download(item)
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(item.fileExtension)

            try data.write(to: temporaryURL)
            player = AVPlayer(url: temporaryURL)
            player?.play()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct AuthenticatedImage: View {
    @EnvironmentObject private var vault: VaultModel

    let item: VaultItem

    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard let request = vault.request(for: item) else {
            failed = true
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            if let uiImage = UIImage(data: data) {
                image = Image(uiImage: uiImage)
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
