import SwiftUI

/// Loads a Frigate image (thumbnail / snapshot) through our authenticated, self-signed-trusting session.
struct AuthImage<Placeholder: View>: View {
    let client: FrigateClient
    let path: String
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            image = nil
            if let data = try? await client.imageData(path), let ui = UIImage(data: data) { image = ui }
        }
    }
}

/// A live camera feed: refreshes Frigate's latest.jpg a bit under once a second.
struct LiveSnapshot: View {
    let client: FrigateClient
    let camera: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 8) {
                    if failed {
                        Image(systemName: "video.slash").font(.title)
                        Text("No feed").font(.caption)
                    } else {
                        ProgressView().tint(.white)
                        Text(camera).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .task(id: camera) {
            while !Task.isCancelled {
                do {
                    let data = try await client.imageData(client.snapshotPath(camera, height: 540))
                    if let ui = UIImage(data: data) { image = ui; failed = false }
                } catch {
                    if image == nil { failed = true }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

extension String {
    /// "tapo_c200" -> "Tapo C200"
    var prettyCamera: String {
        split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
