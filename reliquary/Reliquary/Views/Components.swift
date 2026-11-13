import SwiftUI

/// A pointed gothic arch, like a cathedral window.
struct ArchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let r = w * 0.85                                   // radius: a slightly blunt "lancet" arch
        let offset = r - w / 2
        let rise = sqrt(max(0, r * r - offset * offset))   // height of the arch above the spring line
        let spring = rect.minY + rise
        let apexAngle = atan2(rise, offset)                // angle of the apex seen from each centre
        let steps = 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: spring))
        // Left curve, centred r to the right of the left edge, sweeping from the edge up to the apex.
        for i in 1...steps {
            let t = CGFloat.pi - apexAngle * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: rect.minX + r + r * cos(t), y: spring - r * sin(t)))
        }
        // Right curve, centred r to the left of the right edge, sweeping down to the right edge.
        for i in 1...steps {
            let t = apexAngle - apexAngle * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: rect.maxX - r + r * cos(t), y: spring - r * sin(t)))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A thumbnail that loads from the server and fades in.
struct Thumbnail: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Text("✠")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.crimson.opacity(0.5))
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageLoader.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            let loaded = await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}

/// One square in a grid.
struct MediaCell: View {
    @EnvironmentObject private var store: GalleryStore
    let item: MediaItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(Thumbnail(url: store.client?.thumbURL(item.path)))
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        if let duration = item.durationText {
                            Text(duration).font(Theme.engraved(10))
                        }
                    }
                    .foregroundStyle(Theme.bone)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if store.isFavorite(item) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.blood)
                        .shadow(color: .black, radius: 2)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(Text("\(item.isVideo ? "Video" : "Photo"), \(item.date.formatted(date: .long, time: .omitted))"))
    }
}

/// A grid that can be pinched to show more or fewer columns.
struct PinchColumns: ViewModifier {
    @Binding var columns: Int

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onEnded { value in
                    withAnimation(.spring(duration: 0.3)) {
                        if value.magnification > 1.25 { columns = max(1, columns - 1) }
                        if value.magnification < 0.8 { columns = min(7, columns + 1) }
                    }
                }
        )
    }
}

extension View {
    func pinchColumns(_ columns: Binding<Int>) -> some View { modifier(PinchColumns(columns: columns)) }
}

func gridColumns(_ count: Int) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 2), count: max(1, count))
}

/// A month heading: "October · MMXIX".
struct MonthHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.gothic(24))
                .foregroundStyle(Theme.bone)
            Spacer()
            Text("\(count)")
                .font(Theme.engraved(11))
                .foregroundStyle(Theme.ash)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(
            LinearGradient(colors: [Theme.void, Theme.void.opacity(0.85), Theme.void.opacity(0)], startPoint: .top, endPoint: .bottom)
        )
    }
}

struct EmptyCrypt: View {
    let title: String
    let message: String
    var loading = false

    var body: some View {
        VStack(spacing: 16) {
            if loading {
                ProgressView().tint(Theme.blood).scaleEffect(1.4)
            } else {
                Text("✠")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.crimson)
                    .shadow(color: Theme.blood, radius: 14)
            }
            Text(title)
                .font(Theme.gothic(32))
                .foregroundStyle(Theme.bone)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.serifItalic(16))
                .foregroundStyle(Theme.ash)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

/// What the full-screen viewer shows.
struct ViewerContext: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let start: Int
}
