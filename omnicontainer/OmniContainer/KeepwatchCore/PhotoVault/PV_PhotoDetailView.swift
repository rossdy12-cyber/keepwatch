import SwiftUI

struct PVPhotoDetailView: View {
    let client: PVPhotoPrismClient
    let photo: PVPhoto
    let previewToken: String?

    var body: some View {
        VStack {
            if let url = client.thumbnailURL(for: photo, previewToken: previewToken, size: 1600) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        ContentUnavailableView("Preview unavailable", systemImage: "photo")
                    @unknown default:
                        ProgressView()
                    }
                }
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
            }

            if let title = photo.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .padding(.top, 8)
            }

            if let fileName = photo.fileName {
                Text(fileName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(photo.title ?? "Photo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
