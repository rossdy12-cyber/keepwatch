import SwiftUI

struct WallpaperView: View {
    @EnvironmentObject var store: ThemeStore
    @State private var showClock = true
    @State private var device = DevicePreset.current
    @State private var toast: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Phone-shaped live preview of the active theme.
                    ZStack {
                        WallpaperArt(spec: store.selected, showClock: showClock)
                    }
                    .aspectRatio(9.0/19.5, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 2)
                    )
                    .shadow(radius: 20, y: 10)
                    .padding(.horizontal)

                    VStack(spacing: 14) {
                        Toggle("Clock & date overlay", isOn: $showClock)

                        Picker("Resolution", selection: $device) {
                            ForEach(DevicePreset.all) { Text($0.name).tag($0) }
                        }

                        Button {
                            Task { await saveBoth() }
                        } label: {
                            Label(busy ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(busy)

                        Text("Saved to Photos, then set from **Settings ▸ Wallpaper ▸ Add New Wallpaper ▸ Photos**. The clock overlay is a preview — iOS draws its own live clock on the lock screen, so leave it off for the home screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Wallpaper")
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    @MainActor
    private func saveBoth() async {
        busy = true; defer { busy = false }
        let size = device.pixelSize
        var ok = 0
        if let lock = Renderers.wallpaper(store.selected, size: size, showClock: showClock),
           await Renderers.save(lock) { ok += 1 }
        flash(ok > 0 ? "Wallpaper saved to Photos" : "Couldn't save — allow Photos access in Settings")
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { toast = nil } }
    }
}

struct DevicePreset: Identifiable, Hashable {
    let name: String
    let w: CGFloat
    let h: CGFloat
    var id: String { name }
    var pixelSize: CGSize { CGSize(width: w, height: h) }

    static let all: [DevicePreset] = [
        .init(name: "iPhone 15/16 (1179×2556)", w: 1179, h: 2556),
        .init(name: "iPhone Pro Max (1290×2796)", w: 1290, h: 2796),
        .init(name: "iPhone SE/8 (750×1334)", w: 750, h: 1334),
        .init(name: "iPad (1640×2360)", w: 1640, h: 2360),
    ]

    static var current: DevicePreset {
        let s = UIScreen.main.nativeBounds.size
        let longSide = max(s.width, s.height)
        return all.min(by: { abs($0.h - longSide) < abs($1.h - longSide) }) ?? all[0]
    }
}
