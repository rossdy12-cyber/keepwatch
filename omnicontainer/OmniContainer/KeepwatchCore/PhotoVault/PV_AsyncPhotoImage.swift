import SwiftUI

struct PVAsyncPhotoImage: View {
    let client: PVPhotoPrismClient
    let photo: PVPhoto
    let previewToken: String?

    var body: some View {
        ZStack {
            Color(.systemGray6)

            if let url = client.thumbnailURL(for: photo, previewToken: previewToken, size: 480) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    @unknown default:
                        ProgressView()
                    }
                }
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
