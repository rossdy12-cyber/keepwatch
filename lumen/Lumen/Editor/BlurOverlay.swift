import SwiftUI

/// Shows the privacy-blur regions over the preview, each with a tap target to remove it.
/// Same coordinate space as the editor preview (scaled-to-fit with 8pt padding).
struct BlurOverlay: View {
    let regions: [BlurRegion]
    let imageSize: CGSize
    var onRemove: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let frame = MaskOverlay.fittedRect(container: geometry.size, image: imageSize, padding: 8)
            ForEach(regions) { region in
                let rect = CGRect(x: frame.minX + region.rect.minX * frame.width,
                                  y: frame.minY + region.rect.minY * frame.height,
                                  width: region.rect.width * frame.width,
                                  height: region.rect.height * frame.height)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topTrailing) {
                        Button { onRemove(region.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .offset(x: 9, y: -9)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(true)
    }
}
