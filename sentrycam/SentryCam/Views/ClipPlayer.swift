import SwiftUI
import AVKit

/// Plays an event's recorded clip. Downloads it through our authenticated session first, then plays the local
/// file, so AVPlayer never has to deal with Frigate's login or self-signed certificate.
struct ClipPlayer: View {
    let client: FrigateClient
    let event: FrigateEvent
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                } else if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("\(event.label.capitalized) · \(event.camera.prettyCamera)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                guard event.hasClip else { error = "No clip for this event — snapshot only."; return }
                do {
                    let url = try await client.downloadClip(event.id)
                    let p = AVPlayer(url: url)
                    player = p
                    p.play()
                } catch {
                    self.error = describeError(error)
                }
            }
            .onDisappear { player?.pause() }
        }
    }
}
