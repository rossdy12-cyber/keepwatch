import SwiftUI
import UIKit
import Photos

/// Renders themed images (wallpapers and icon tiles) and saves them to the photo library.
enum Renderers {

    /// A full-screen wallpaper for the given theme. `clock` adds a soft time/date hint
    /// so the lock screen reads well; the home-screen variant leaves it off.
    @MainActor
    static func wallpaper(_ spec: ThemeSpec, size: CGSize, showClock: Bool) -> UIImage? {
        let view = WallpaperArt(spec: spec, showClock: showClock).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(size)
        renderer.scale = 1   // size is already in device pixels
        return renderer.uiImage
    }

    /// A rounded app-icon tile: theme background + an SF Symbol glyph in the accent colour.
    @MainActor
    static func iconTile(_ spec: ThemeSpec, symbol: String, px: CGFloat = 512) -> UIImage? {
        let view = IconArt(spec: spec, symbol: symbol).frame(width: px, height: px)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(CGSize(width: px, height: px))
        renderer.scale = 1
        return renderer.uiImage
    }

    static func save(_ image: UIImage) async -> Bool {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { c in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { ok, _ in c.resume(returning: ok) }
        }
    }
}

/// Wallpaper artwork: the theme background, optionally with a large clock hint.
struct WallpaperArt: View {
    let spec: ThemeSpec
    let showClock: Bool

    var body: some View {
        ZStack {
            ThemeBackground(spec: spec)
            if showClock {
                GeometryReader { geo in
                    VStack(spacing: geo.size.height * 0.004) {
                        Text("9:41")
                            .font(.system(size: geo.size.width * 0.17, weight: .semibold, design: .rounded))
                        Text("Monday, 11 November")
                            .font(.system(size: geo.size.width * 0.045, weight: .medium, design: .rounded))
                            .opacity(0.85)
                    }
                    .foregroundStyle(spec.textColor)
                    .frame(width: geo.size.width, alignment: .center)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.17)
                }
            }
        }
    }
}

/// Icon artwork: theme background clipped to an iOS-style squircle, with a centred glyph.
struct IconArt: View {
    let spec: ThemeSpec
    let symbol: String

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ThemeBackground(spec: spec)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(spec.accentColor)
                    .shadow(color: .black.opacity(0.25), radius: side * 0.01, y: side * 0.006)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        }
    }
}
