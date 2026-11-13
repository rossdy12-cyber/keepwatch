import AVKit
import SwiftUI

struct ViewerView: View {
    @EnvironmentObject private var store: GalleryStore
    @Environment(\.dismiss) private var dismiss

    let items: [MediaItem]
    @State private var selection: String
    @State private var chrome = true
    @State private var zoomed = false
    @State private var dragOffset: CGFloat = 0
    @State private var showInfo = false
    @State private var slideshow = false
    @State private var sharing: ShareFile?
    @State private var preparingShare = false
    @State private var shareError: String?

    init(context: ViewerContext) {
        items = context.items
        let start = context.items.indices.contains(context.start) ? context.start : 0
        _selection = State(initialValue: context.items.isEmpty ? "" : context.items[start].path)
    }

    private var current: MediaItem? { items.first { $0.path == selection } }
    private var currentIndex: Int { items.firstIndex { $0.path == selection } ?? 0 }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(0.7, Double(abs(dragOffset)) / 600.0))
                .ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(items) { item in
                    Group {
                        if item.isVideo {
                            VideoPage(item: item, isCurrent: item.path == selection)
                        } else {
                            ImagePage(item: item, zoomed: item.path == selection ? $zoomed : .constant(false))
                        }
                    }
                    .tag(item.path)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDrag)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }

            if chrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if preparingShare {
                ProgressView("Exhuming the original…")
                    .font(Theme.serifItalic(15))
                    .tint(Theme.blood)
                    .foregroundStyle(Theme.bone)
                    .padding(24)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .statusBarHidden(!chrome)
        .onChange(of: selection) { _, _ in zoomed = false }
        .task(id: slideshow) {
            guard slideshow else { return }
            withAnimation { chrome = false }
            while slideshow, !Task.isCancelled {
                let wait = current?.isVideo == true ? max(5, (current?.duration ?? 5) + 1) : 5
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard slideshow, !Task.isCancelled else { break }
                let next = currentIndex + 1
                if next < items.count {
                    withAnimation(.easeInOut(duration: 0.8)) { selection = items[next].path }
                } else {
                    slideshow = false
                    withAnimation { chrome = true }
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let current {
                InfoSheet(item: current)
                    .presentationDetents([.medium])
                    .presentationBackground(Theme.void)
            }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url)
        }
        .alert("Couldn't share", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { value in
                guard !zoomed, abs(value.translation.height) > abs(value.translation.width) * 1.4 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard !zoomed else { return }
                if abs(dragOffset) > 140 || abs(value.predictedEndTranslation.height) > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 2) {
                if let current {
                    Text(current.date.formatted(date: .long, time: .shortened))
                        .font(Theme.serif(16, weight: .semibold))
                        .foregroundStyle(Theme.bone)
                    Text(current.name)
                        .font(Theme.serifItalic(13))
                        .foregroundStyle(Theme.ash)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("\(currentIndex + 1) / \(items.count)")
                .font(Theme.engraved(11))
                .foregroundStyle(Theme.ash)
        }
        .foregroundStyle(Theme.bone)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var bottomBar: some View {
        HStack {
            if let current {
                Button {
                    Task { await store.toggleFavorite(current) }
                } label: {
                    Image(systemName: store.isFavorite(current) ? "heart.fill" : "heart")
                        .foregroundStyle(store.isFavorite(current) ? Theme.blood : Theme.bone)
                }
                .accessibilityLabel(store.isFavorite(current) ? "Remove from Relics" : "Add to Relics")
                Spacer()
                Button {
                    Task { await share(current) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                Spacer()
                Button {
                    slideshow.toggle()
                    if !slideshow { withAnimation { chrome = true } }
                } label: {
                    Image(systemName: slideshow ? "pause.fill" : "play.square.stack")
                }
                .accessibilityLabel(slideshow ? "Stop slideshow" : "Slideshow")
                Spacer()
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Details")
            }
        }
        .font(.system(size: 21))
        .foregroundStyle(Theme.bone)
        .padding(.horizontal, 34)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func share(_ item: MediaItem) async {
        guard let client = store.client else { return }
        preparingShare = true
        defer { preparingShare = false }
        do {
            sharing = ShareFile(url: try await client.download(item))
        } catch {
            shareError = error.localizedDescription
        }
    }
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: Pages

struct ImagePage: View {
    @EnvironmentObject private var store: GalleryStore
    let item: MediaItem
    @Binding var zoomed: Bool
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, zoomed: $zoomed)
            } else if failed {
                VStack(spacing: 10) {
                    Text("✠").font(.system(size: 30)).foregroundStyle(Theme.crimson)
                    Text("This image couldn't be raised.")
                        .font(Theme.serifItalic(15))
                        .foregroundStyle(Theme.ash)
                }
            } else {
                // The small grid thumbnail, blown up, while the large one loads.
                Thumbnail(url: store.client?.thumbURL(item.path), contentMode: .fit)
                    .blur(radius: 6)
                ProgressView().tint(Theme.blood)
            }
        }
        .task(id: item.path) {
            guard let client = store.client else { return }
            // 1. A 1600-pixel version from the server: quick, and enough for the screen.
            let large = await ImageLoader.shared.image(for: client.thumbURL(item.path, large: true))
            if let large { image = large }
            // 2. The original, for detail when zooming in.
            if item.hasDisplayableOriginal,
               let original = await ImageLoader.shared.image(for: client.fileURL(item.path), maxPixel: 4096),
               !Task.isCancelled {
                image = original
            }
            if image == nil { failed = true }
        }
    }
}

/// UIScrollView-based zoom: pinch, double-tap and pan feel like Photos.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(zoomed: $zoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
        if !zoomed, scroll.zoomScale != 1 {
            scroll.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var zoomed: Binding<Bool>
        weak var imageView: UIImageView?

        init(zoomed: Binding<Bool>) {
            self.zoomed = zoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > 1.01
            if zoomed.wrappedValue != isZoomed {
                DispatchQueue.main.async { self.zoomed.wrappedValue = isZoomed }
            }
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 3
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

struct VideoPage: View {
    @EnvironmentObject private var store: GalleryStore
    let item: MediaItem
    let isCurrent: Bool
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                Thumbnail(url: store.client?.thumbURL(item.path, large: true), contentMode: .fit)
                if item.isPlayable {
                    Button {
                        start()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.bone, Theme.crimson)
                            .shadow(color: Theme.blood, radius: 12)
                    }
                    .accessibilityLabel("Play")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film")
                            .font(.system(size: 34))
                        Text("iPhone can't play .\((item.name as NSString).pathExtension) videos here.\nShare it to open in another app.")
                            .font(Theme.serifItalic(14))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.bone)
                    .padding(18)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onChange(of: isCurrent) { _, now in
            if !now {
                player?.pause()
            } else if player == nil, item.isPlayable {
                start()
            }
        }
        .onAppear {
            if isCurrent, item.isPlayable { start() }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func start() {
        guard let client = store.client else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let newPlayer = AVPlayer(url: client.fileURL(item.path))
        player = newPlayer
        newPlayer.play()
    }
}

// MARK: Info

struct InfoSheet: View {
    let item: MediaItem

    var body: some View {
        ZStack {
            GothicBackground()
            VStack(alignment: .leading, spacing: 14) {
                Text("Provenance")
                    .font(Theme.gothic(30))
                    .foregroundStyle(Theme.bone)
                OrnamentDivider()
                row("Name", item.name)
                row("Taken", item.date.formatted(date: .complete, time: .shortened))
                row("Folder", item.folder.isEmpty ? "IDrive-Sync" : item.folder)
                if let width = item.width, let height = item.height {
                    row("Size", "\(width) × \(height)" + megapixels(width, height))
                }
                row("File", ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                if let duration = item.durationText {
                    row("Length", duration)
                }
                Spacer()
            }
            .padding(24)
        }
    }

    private func megapixels(_ w: Int, _ h: Int) -> String {
        guard !item.isVideo else { return "" }
        return String(format: " · %.1f MP", Double(w * h) / 1_000_000)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.engraved(11))
                .tracking(2)
                .foregroundStyle(Theme.ash)
            Text(value)
                .font(Theme.serif(17))
                .foregroundStyle(Theme.bone)
                .textSelection(.enabled)
        }
    }
}
