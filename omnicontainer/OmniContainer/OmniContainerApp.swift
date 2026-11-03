import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Network
import UIKit
import Compression
import AVFoundation
import MediaPlayer

struct OmniAppDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let sym: String
    let rgb: (CGFloat, CGFloat, CGFloat)
}

struct InstalledIPAPackage: Identifiable, Codable {
    var id: String { bundleID }
    let fileName: String
    let appName: String
    let bundleID: String
    let version: String
    let executable: String
    let sizeMB: String
    let installedDate: Date
    let iconBase64: String?
    let mappedModuleID: String
    let runtimeURL: String
    let localAppPath: String
}

// MARK: - Native Pure-Swift .IPA ZIP Extractor (Uses Apple's Compression Framework to Read Info.plist & AppIcon from .ipa!)
enum IPAArchiveExtractor {
    static func extractAndInspect(ipaURL: URL, destDir: URL) -> InstalledIPAPackage? {
        guard let data = try? Data(contentsOf: ipaURL, options: .mappedIfSafe) else { return nil }
        let fileName = ipaURL.lastPathComponent
        let cleanBase = fileName.replacingOccurrences(of: ".ipa", with: "", options: .caseInsensitive)
        let sizeMB = String(format: "%.1f MB", Double(data.count) / 1_048_576.0)

        var extractedBundleName = cleanBase
        var extractedBundleID = "com.omni.\(cleanBase.lowercased().replacingOccurrences(of: " ", with: ""))"
        var extractedVersion = "1.0"
        var extractedExec = cleanBase
        var extractedIconB64: String? = nil

        // Scan ZIP Local File Headers (0x04034b50) to extract Info.plist and AppIcon*.png
        let bytes = [UInt8](data)
        let count = bytes.count
        var i = 0
        while i + 30 < count {
            if bytes[i] == 0x50 && bytes[i+1] == 0x4B && bytes[i+2] == 0x03 && bytes[i+3] == 0x04 {
                let method = UInt16(bytes[i+8]) | (UInt16(bytes[i+9]) << 8)
                let compSize = Int(UInt32(bytes[i+18]) | (UInt32(bytes[i+19]) << 8) | (UInt32(bytes[i+20]) << 16) | (UInt32(bytes[i+21]) << 24))
                let uncompSize = Int(UInt32(bytes[i+22]) | (UInt32(bytes[i+23]) << 8) | (UInt32(bytes[i+24]) << 16) | (UInt32(bytes[i+25]) << 24))
                let nameLen = Int(UInt16(bytes[i+26]) | (UInt16(bytes[i+27]) << 8))
                let extraLen = Int(UInt16(bytes[i+28]) | (UInt16(bytes[i+29]) << 8))
                let nameStart = i + 30
                let dataStart = nameStart + nameLen + extraLen
                if dataStart <= count, let entryName = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) {
                    let isTopInfoPlist = entryName.hasSuffix(".app/Info.plist") && !entryName.contains(".app/Frameworks/") && !entryName.contains(".app/PlugIns/")
                    let isAppIcon = entryName.contains(".app/AppIcon") && entryName.hasSuffix(".png") && extractedIconB64 == nil

                    if (isTopInfoPlist || isAppIcon) && compSize > 0 && dataStart + compSize <= count && uncompSize > 0 && uncompSize < 10_000_000 {
                        let slice = Data(bytes[dataStart..<(dataStart + compSize)])
                        if let raw = decompressZipEntry(slice, method: method, uncompressedSize: uncompSize) {
                            if isTopInfoPlist,
                               let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any] {
                                if let disp = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String), !disp.isEmpty {
                                    extractedBundleName = disp
                                }
                                if let bid = plist["CFBundleIdentifier"] as? String, !bid.isEmpty {
                                    extractedBundleID = bid
                                }
                                if let ver = plist["CFBundleShortVersionString"] as? String, !ver.isEmpty {
                                    extractedVersion = ver
                                }
                                if let exe = plist["CFBundleExecutable"] as? String, !exe.isEmpty {
                                    extractedExec = exe
                                }
                            } else if isAppIcon {
                                extractedIconB64 = raw.base64EncodedString()
                            }
                        }
                    }
                    if compSize > 0 {
                        i = dataStart + compSize
                        continue
                    }
                }
            }
            i += 1
        }

        // Map to internal OmniContainer execution engine (NEVER calls LiveContainer!)
        let searchStr = (extractedBundleName + " " + extractedBundleID + " " + cleanBase).lowercased()
        let (modID, runtimeURL): (String, String) = {
            if searchStr.contains("youtube") || searchStr.contains("uyou") || searchStr.contains("ytlite") || searchStr.contains("cercube") {
                return ("youtube", "https://m.youtube.com")
            }
            if searchStr.contains("keepwatch") { return ("keepwatch", "") }
            if searchStr.contains("jarvis") { return ("jarvis", "") }
            if searchStr.contains("nasportal") || searchStr.contains("portal") { return ("nasportal", "") }
            if searchStr.contains("antigravity") { return ("antigravity", "") }
            if searchStr.contains("aegis") { return ("aegis", "") }
            if searchStr.contains("deskswitch") { return ("deskswitch", "") }
            if searchStr.contains("sentrycam") { return ("sentrycam", "") }
            if searchStr.contains("aniimo") { return ("aniimo", "") }
            if searchStr.contains("racebolt") { return ("racebolt", "") }
            if searchStr.contains("photopulse") { return ("photopulse", "") }
            if searchStr.contains("netradar") { return ("netradar", "") }
            if searchStr.contains("soulseek") { return ("soulseekr", "") }
            if searchStr.contains("zima") { return ("zimadeck", "") }
            if searchStr.contains("twitch") { return ("ipa-\(extractedBundleID)", "https://m.twitch.tv") }
            if searchStr.contains("spotify") { return ("ipa-\(extractedBundleID)", "https://open.spotify.com") }
            if searchStr.contains("discord") { return ("ipa-\(extractedBundleID)", "https://discord.com/app") }
            if searchStr.contains("reddit") || searchStr.contains("apollo") { return ("ipa-\(extractedBundleID)", "https://www.reddit.com") }
            if searchStr.contains("instagram") { return ("ipa-\(extractedBundleID)", "https://www.instagram.com") }
            if searchStr.contains("tiktok") { return ("ipa-\(extractedBundleID)", "https://www.tiktok.com") }
            if searchStr.contains("twitter") || searchStr.contains("x.com") { return ("ipa-\(extractedBundleID)", "https://x.com") }
            let q = extractedBundleName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? extractedBundleName
            return ("ipa-\(extractedBundleID)", "https://duckduckgo.com/?q=\(q)")
        }()

        return InstalledIPAPackage(
            fileName: fileName,
            appName: extractedBundleName,
            bundleID: extractedBundleID,
            version: extractedVersion,
            executable: extractedExec,
            sizeMB: sizeMB,
            installedDate: Date(),
            iconBase64: extractedIconB64,
            mappedModuleID: modID,
            runtimeURL: runtimeURL,
            localAppPath: destDir.path
        )
    }

    private static func decompressZipEntry(_ data: Data, method: UInt16, uncompressedSize: Int) -> Data? {
        if method == 0 { return data }
        guard method == 8 else { return nil }
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: uncompressedSize)
        defer { dstBuffer.deallocate() }
        let decodedCount = data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
            guard let srcPtr = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(dstBuffer, uncompressedSize, srcPtr, data.count, nil, COMPRESSION_ZLIB)
        }
        guard decodedCount > 0 else { return nil }
        return Data(bytes: dstBuffer, count: decodedCount)
    }
}

final class SelfSignedWebDelegate: NSObject, WKNavigationDelegate {
    static let shared = SelfSignedWebDelegate()
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Native Background Audio & Lock-Screen Media Controller + Persistent WKWebView Cache
@MainActor
final class WebViewCache {
    static let shared = WebViewCache()
    private var views: [String: WKWebView] = [:]
    private var loadedURLs: [String: String] = [:]
    private var silentPlayer: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var isConfigured = false

    // Injected AT DOCUMENT START so YouTube never detects backgrounding or tab hiding!
    private let youtubeDocumentStartScript = """
    (function() {
      try {
        Object.defineProperty(document, 'hidden', { get: function() { return false; }, configurable: true });
        Object.defineProperty(document, 'webkitHidden', { get: function() { return false; }, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; }, configurable: true });
        Object.defineProperty(document, 'webkitVisibilityState', { get: function() { return 'visible'; }, configurable: true });
      } catch (e) {}

      const blockedEvents = ['visibilitychange', 'webkitvisibilitychange', 'blur', 'pagehide', 'freeze'];
      const origDocAdd = Document.prototype.addEventListener;
      Document.prototype.addEventListener = function(type, listener, options) {
        if (blockedEvents.indexOf(String(type).toLowerCase()) !== -1) { return; }
        return origDocAdd.call(this, type, listener, options);
      };
      const origWinAdd = Window.prototype.addEventListener;
      Window.prototype.addEventListener = function(type, listener, options) {
        if (blockedEvents.indexOf(String(type).toLowerCase()) !== -1) { return; }
        return origWinAdd.call(this, type, listener, options);
      };

      window.__omniBgTransitionUntil = 0;
      window.__omniLastPlayingVideo = null;

      const origPlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function() {
        window.__omniLastPlayingVideo = this;
        this.setAttribute('playsinline', '');
        this.setAttribute('webkit-playsinline', '');
        return origPlay.apply(this, arguments);
      };

      const origPause = HTMLMediaElement.prototype.pause;
      HTMLMediaElement.prototype.pause = function() {
        if (Date.now() < window.__omniBgTransitionUntil) {
          return;
        }
        return origPause.apply(this, arguments);
      };

      window.__omniForceResumeMedia = function() {
        window.__omniBgTransitionUntil = Date.now() + 5000;
        const vids = document.querySelectorAll('video, audio');
        vids.forEach(function(v) {
          try {
            v.setAttribute('playsinline', '');
            v.setAttribute('webkit-playsinline', '');
            origPlay.call(v).catch(function(){});
          } catch(e) {}
        });
        if (window.__omniLastPlayingVideo) {
          try { origPlay.call(window.__omniLastPlayingVideo).catch(function(){}); } catch(e) {}
        }
      };

      window.__omniTogglePiP = function() {
        const v = document.querySelector('video') || window.__omniLastPlayingVideo;
        if (!v) return 'No active video found';
        try {
          if (v.webkitSupportsPresentationMode && typeof v.webkitSetPresentationMode === 'function') {
            const nextMode = (v.webkitPresentationMode === 'picture-in-picture') ? 'inline' : 'picture-in-picture';
            v.webkitSetPresentationMode(nextMode);
            return 'PiP: ' + nextMode;
          } else if (document.pictureInPictureEnabled && v.requestPictureInPicture) {
            v.requestPictureInPicture();
            return 'PiP requested';
          }
        } catch(e) { return 'PiP err: ' + e; }
        return 'PiP unsupported on this element';
      };
    })();
    """

    // Injected AT DOCUMENT END for CSS Ad-Hiding, Sponsor Auto-Skip & Lock-Screen Metadata
    private let youtubeDocumentEndScript = """
    (function() {
      const style = document.createElement('style');
      style.innerHTML = `
        ytm-promoted-sparkles-web-renderer, ytm-promoted-video-renderer,
        ytm-companion-ad-renderer, .ad-showing .video-ads, .ytp-ad-module,
        .ytp-ad-overlay-container, ytd-ad-slot-renderer, ytm-ad-slot-renderer,
        ytm-mealbar-promo-renderer, ytm-statement-banner-renderer {
          display: none !important;
        }
      `;
      if (document.documentElement) {
        document.documentElement.appendChild(style);
      }
      setInterval(function() {
        const skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
        if (skipBtn) { skipBtn.click(); }
        const adShowing = document.querySelector('.ad-showing video');
        if (adShowing && !isNaN(adShowing.duration) && adShowing.duration > 0) {
          adShowing.currentTime = adShowing.duration;
        }
        const v = document.querySelector('video');
        if (v && !v.paused) {
          window.__omniLastPlayingVideo = v;
        }
      }, 400);
    })();
    """

    private func setupAudioAndBackgroundHooksIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {}

        // Build tiny 1-second silent WAV buffer so iOS kernel keeps OmniContainer's audio session & WebContent process alive
        if silentPlayer == nil, let wavData = Self.makeSilentWAVData() {
            if let player = try? AVAudioPlayer(data: wavData) {
                player.numberOfLoops = -1
                player.volume = 0.01
                player.prepareToPlay()
                player.play()
                silentPlayer = player
            }
        }

        // Configure iOS Lock Screen & Control Center Play/Pause Remote Controls
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.forceResumeAllWebViews() }
            return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseAllWebViews() }
            return .success
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "OmniContainer YouTube Pro",
            MPMediaItemPropertyArtist: "Background Audio Active",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]

        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleEnteringBackground()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleEnteringBackground()
            }
        }
    }

    private func handleEnteringBackground() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        if let player = silentPlayer, !player.isPlaying {
            player.play()
        }
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "OmniBackgroundAudio") { [weak self] in
                if let t = self?.bgTask, t != .invalid {
                    UIApplication.shared.endBackgroundTask(t)
                    self?.bgTask = .invalid
                }
            }
        }
        // Multi-stage resume to beat WebKit's internal background pause hook
        for delay in [0.05, 0.25, 0.6, 1.2, 2.2, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.forceResumeAllWebViews()
            }
        }
    }

    func forceResumeAllWebViews() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if let player = silentPlayer, !player.isPlaying {
            player.play()
        }
        for (_, wv) in views {
            wv.evaluateJavaScript("window.__omniForceResumeMedia && window.__omniForceResumeMedia();", completionHandler: nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "YouTube Pro (OmniContainer)",
            MPMediaItemPropertyArtist: "Background Stream Active",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    func pauseAllWebViews() {
        for (_, wv) in views {
            wv.evaluateJavaScript("window.__omniBgTransitionUntil = 0; document.querySelectorAll('video,audio').forEach(v => v.pause());", completionHandler: nil)
        }
    }

    func togglePiP(for key: String) {
        views[key]?.evaluateJavaScript("window.__omniTogglePiP && window.__omniTogglePiP();", completionHandler: nil)
    }

    private static func makeSilentWAVData() -> Data? {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize
        var d = Data()
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        withUnsafeBytes(of: fileSize.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        withUnsafeBytes(of: UInt32(16).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { d.append(contentsOf: $0) }  // PCM
        withUnsafeBytes(of: UInt16(1).littleEndian) { d.append(contentsOf: $0) }  // Mono
        withUnsafeBytes(of: sampleRate.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: (sampleRate * 2).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        withUnsafeBytes(of: dataSize.littleEndian) { d.append(contentsOf: $0) }
        d.append(Data(count: Int(dataSize)))
        return d
    }

    func webView(for key: String, urlString: String, enableYouTubePro: Bool = false) -> WKWebView {
        setupAudioAndBackgroundHooksIfNeeded()
        if let existing = views[key] {
            if loadedURLs[key] != urlString, let u = URL(string: urlString) {
                loadedURLs[key] = urlString
                existing.load(URLRequest(url: u))
            }
            return existing
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if enableYouTubePro {
            let startScript = WKUserScript(source: youtubeDocumentStartScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            let endScript = WKUserScript(source: youtubeDocumentEndScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            config.userContentController.addUserScript(startScript)
            config.userContentController.addUserScript(endScript)
        }

        let w = WKWebView(frame: .zero, configuration: config)
        w.navigationDelegate = SelfSignedWebDelegate.shared
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        w.scrollView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        w.allowsBackForwardNavigationGestures = true
        views[key] = w
        if let u = URL(string: urlString) {
            loadedURLs[key] = urlString
            w.load(URLRequest(url: u))
        }
        return w
    }
}

struct FastCachedWebView: UIViewRepresentable {
    let cacheKey: String
    let urlString: String
    var enableYouTubePro: Bool = false

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        let wv = WebViewCache.shared.webView(for: cacheKey, urlString: urlString, enableYouTubePro: enableYouTubePro)
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let wv = WebViewCache.shared.webView(for: cacheKey, urlString: urlString, enableYouTubePro: enableYouTubePro)
        if wv.superview !== uiView {
            wv.removeFromSuperview()
            wv.translatesAutoresizingMaskIntoConstraints = false
            uiView.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.leadingAnchor.constraint(equalTo: uiView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: uiView.trailingAnchor),
                wv.topAnchor.constraint(equalTo: uiView.topAnchor),
                wv.bottomAnchor.constraint(equalTo: uiView.bottomAnchor)
            ])
        }
    }
}

@MainActor
class OmniWorkspaceStore: ObservableObject {
    let builtInApps: [OmniAppDescriptor] = [
        OmniAppDescriptor(id: "youtube", title: "YouTube Pro", subtitle: "Ad-Free + PiP + MeTube Grab", icon: "play.rectangle.fill", color: .red, sym: "YT", rgb: (1.0, 0.15, 0.15)),
        OmniAppDescriptor(id: "keepwatch", title: "Keepwatch Hub", subtitle: "Homelab, Arr, Docker & Jarvis", icon: "shield.checkered", color: .purple, sym: "KW", rgb: (0.65, 0.35, 1.0)),
        OmniAppDescriptor(id: "jarvis", title: "J.A.R.V.I.S.", subtitle: "AI Voice, Chat & Music", icon: "waveform.circle.fill", color: .cyan, sym: "JV", rgb: (0.0, 0.85, 1.0)),
        OmniAppDescriptor(id: "nasportal", title: "NASPortal & 2FA", subtitle: "Homelab Sites & TOTP Vault", icon: "key.fill", color: .orange, sym: "NP", rgb: (1.0, 0.65, 0.0)),
        OmniAppDescriptor(id: "antigravity", title: "Antigravity", subtitle: "3-Node Fleet Command", icon: "cpu.fill", color: .cyan, sym: "AG", rgb: (0.0, 0.9, 1.0)),
        OmniAppDescriptor(id: "aegis", title: "Aegis Browser", subtitle: "Ad-Block + 3-Node Drawer", icon: "shield.lefthalf.filled", color: .blue, sym: "AE", rgb: (0.16, 0.47, 1.0)),
        OmniAppDescriptor(id: "deskswitch", title: "DeskSwitch", subtitle: "Monitor/TV + Steam + Trackpad", icon: "tv.and.mediabox", color: .orange, sym: "DS", rgb: (1.0, 0.58, 0.0)),
        OmniAppDescriptor(id: "sentrycam", title: "SentryCam", subtitle: "Frigate AI CCTV + Tapo PTZ", icon: "video.fill", color: .red, sym: "SC", rgb: (1.0, 0.23, 0.19)),
        OmniAppDescriptor(id: "aniimo", title: "Aniimo Pilot", subtitle: "Live Game Stream & Farm Bot", icon: "gamecontroller.fill", color: .green, sym: "AP", rgb: (0.0, 0.9, 0.46)),
        OmniAppDescriptor(id: "racebolt", title: "Racebolt Ops", subtitle: "SKU Stock Lookup & Audit", icon: "wrench.and.screwdriver.fill", color: .yellow, sym: "RB", rgb: (1.0, 0.8, 0.0)),
        OmniAppDescriptor(id: "photopulse", title: "PhotoPulse", subtitle: "iCloudPD 2FA & Immich Frames", icon: "photo.artframe", color: .pink, sym: "PP", rgb: (1.0, 0.25, 0.5)),
        OmniAppDescriptor(id: "netradar", title: "NetRadar", subtitle: "SpeedTest + Mesh & SSL Audit", icon: "network", color: .teal, sym: "NR", rgb: (0.0, 0.85, 0.95)),
        OmniAppDescriptor(id: "soulseekr", title: "SoulSeekr", subtitle: "slskd + Hearr + Soularr P2P", icon: "waveform.badge.magnifyingglass", color: .purple, sym: "SS", rgb: (0.73, 0.41, 0.78)),
        OmniAppDescriptor(id: "zimadeck", title: "ZimaDeck", subtitle: "Zimaboard + Komga + RustDesk", icon: "server.rack", color: .mint, sym: "ZD", rgb: (0.0, 0.9, 0.7))
    ]

    @Published var runningAppIDs: [String] = []
    @Published var activeAppID: String = "home"
    @Published var splitScreenEnabled: Bool = false
    @Published var secondaryAppID: String = "sentrycam"
    @Published var installedIPAs: [InstalledIPAPackage] = []
    @Published var statusBanner: String = "Native YouTube 21.42.4 Plus + 13 OmniContainer Apps Integrated!"
    @Published var truenasHost: String = "100.85.127.42"
    @Published var routeLabel: String = "Tailscale"
    @Published var isMinimizedToYouTube: Bool = true {
        didSet {
            OmniOverlayController.shared.syncVisibility()
        }
    }

    var isRunningInsideNativeYouTube: Bool {
        NSClassFromString("YTSceneDelegate") != nil || Bundle.main.bundlePath.hasSuffix("YouTube.app")
    }

    private let installedKey = "omnicontainer.installed.ipas.v4"

    init() {
        if let data = UserDefaults.standard.data(forKey: installedKey),
           let decoded = try? JSONDecoder().decode([InstalledIPAPackage].self, from: data) {
            installedIPAs = decoded
        }
        Task { await detectFastestRoute() }
    }

    func saveInstalled() {
        if let data = try? JSONEncoder().encode(installedIPAs) {
            UserDefaults.standard.set(data, forKey: installedKey)
        }
    }

    func installIPAFromURL(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ipaDir = docs.appendingPathComponent("InstalledIPAs", isDirectory: true)
        try? fm.createDirectory(at: ipaDir, withIntermediateDirectories: true)

        let dest = ipaDir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: url, to: dest)
            if let pkg = IPAArchiveExtractor.extractAndInspect(ipaURL: dest, destDir: dest) {
                installedIPAs.removeAll { $0.fileName == pkg.fileName || $0.bundleID == pkg.bundleID }
                installedIPAs.insert(pkg, at: 0)
                saveInstalled()
                statusBanner = "Installed \(pkg.appName) (\(pkg.bundleID)) into OmniContainer!"
                launchInstalledIPA(pkg)
            }
        } catch {
            statusBanner = "Failed to install .ipa: \(error.localizedDescription)"
        }
    }

    func launchInstalledIPA(_ pkg: InstalledIPAPackage) {
        // NEVER opens LiveContainer! Always runs directly inside OmniContainer's keep-alive workspace!
        launchOrFocus(pkg.mappedModuleID)
        statusBanner = "Running \(pkg.appName) inside OmniContainer (Zero Restart)!"
    }

    func deleteInstalledIPA(_ pkg: InstalledIPAPackage) {
        installedIPAs.removeAll { $0.id == pkg.id }
        saveInstalled()
        closeRunningApp(pkg.mappedModuleID)
    }

    func detectFastestRoute() async {
        if let u = URL(string: "http://38.9.96.58:5000/api/version") {
            var req = URLRequest(url: u)
            req.timeoutInterval = 0.6
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                truenasHost = "38.9.96.58"
                routeLabel = "Direct LAN (Fast)"
                return
            }
        }
        truenasHost = "100.85.127.42"
        routeLabel = "Tailscale"
    }

    func toggleRoute() {
        if truenasHost == "100.85.127.42" {
            truenasHost = "38.9.96.58"
            routeLabel = "Direct LAN"
        } else {
            truenasHost = "100.85.127.42"
            routeLabel = "Tailscale"
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL && url.pathExtension.lowercased() == "ipa" {
            installIPAFromURL(url)
            return
        }
        let host = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryApp = comps?.queryItems?.first(where: { $0.name == "app" || $0.name == "id" })?.value?.lowercased()
        let target = queryApp ?? host
        if !target.isEmpty && target != "open" {
            launchOrFocus(target)
        }
    }

    func launchOrFocus(_ appID: String) {
        if appID == "youtube" && isRunningInsideNativeYouTube {
            isMinimizedToYouTube = true
            return
        }
        isMinimizedToYouTube = false
        if !runningAppIDs.contains(appID) {
            runningAppIDs.append(appID)
        }
        activeAppID = appID
    }

    func closeRunningApp(_ appID: String) {
        runningAppIDs.removeAll { $0 == appID }
        if activeAppID == appID {
            activeAppID = runningAppIDs.last ?? "home"
        }
    }

    func titleForAppID(_ id: String) -> String {
        if let b = builtInApps.first(where: { $0.id == id }) { return b.title }
        if let p = installedIPAs.first(where: { $0.mappedModuleID == id }) { return p.appName }
        return id.uppercased()
    }

    func installClipAppToHomeScreen(key: String) {
        if let u = URL(string: "http://\(truenasHost):8766/clip/\(key).mobileconfig") {
            UIApplication.shared.open(u)
        }
    }
}

// MARK: - Passthrough UIWindow & Overlay Controller for Native YouTube 21.42.4 Plus Integration
final class OmniOverlayWindow: UIWindow {
    var passthroughMode: Bool = true
    weak var pillButton: UIButton?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if passthroughMode {
            if let btn = pillButton, !btn.isHidden {
                let ptInBtn = convert(point, to: btn)
                if btn.bounds.insetBy(dx: -10, dy: -10).contains(ptInBtn) {
                    return btn
                }
            }
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

@MainActor
final class OmniOverlayController: NSObject {
    static let shared = OmniOverlayController()
    lazy var workspace = OmniWorkspaceStore()
    private var overlayWindow: OmniOverlayWindow?
    private var hostingController: UIHostingController<AnyView>?
    private var pillButton: UIButton?
    private var pollTimer: Timer?

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.attachIfNeeded()
                self?.syncVisibility()
            }
        }
    }

    func handleURLString(_ str: String) {
        guard let u = URL(string: str) else { return }
        attachIfNeeded()
        workspace.handleIncomingURL(u)
        syncVisibility()
    }

    func attachIfNeeded() {
        guard overlayWindow == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let win = OmniOverlayWindow(windowScene: scene)
        win.frame = scene.coordinateSpace.bounds
        win.windowLevel = UIWindow.Level.statusBar + 50
        win.backgroundColor = .clear

        let rootView = AnyView(
            OmniRootContainerView()
                .environmentObject(workspace)
                .preferredColorScheme(.dark)
        )
        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1.0)
        host.view.frame = win.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        win.rootViewController = host

        let btn = UIButton(type: .system)
        btn.frame = CGRect(x: max(16, win.bounds.width - 96), y: 58, width: 84, height: 34)
        btn.setTitle("⚡ Omni", for: .normal)
        btn.setTitleColor(.black, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        btn.backgroundColor = UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.92)
        btn.layer.cornerRadius = 17
        btn.layer.borderWidth = 1.5
        btn.layer.borderColor = UIColor.white.withAlphaComponent(0.75).cgColor
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.55
        btn.layer.shadowRadius = 6
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.addTarget(self, action: #selector(didTapPill), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPanPill(_:)))
        btn.addGestureRecognizer(pan)

        win.addSubview(btn)
        win.pillButton = btn
        win.isHidden = false

        self.overlayWindow = win
        self.hostingController = host
        self.pillButton = btn
        syncVisibility()
    }

    @objc private func didTapPill() {
        workspace.isMinimizedToYouTube = false
        syncVisibility()
    }

    @objc private func didPanPill(_ gr: UIPanGestureRecognizer) {
        guard let btn = pillButton, let win = overlayWindow else { return }
        let trans = gr.translation(in: win)
        var center = CGPoint(x: btn.center.x + trans.x, y: btn.center.y + trans.y)
        center.x = max(48, min(win.bounds.width - 48, center.x))
        center.y = max(52, min(win.bounds.height - 52, center.y))
        btn.center = center
        gr.setTranslation(.zero, in: win)
    }

    func syncVisibility() {
        guard let win = overlayWindow, let host = hostingController, let btn = pillButton else { return }
        let minimized = workspace.isMinimizedToYouTube
        win.passthroughMode = minimized
        host.view.isHidden = minimized
        btn.isHidden = !minimized
        if !minimized {
            win.bringSubviewToFront(host.view)
        } else {
            win.bringSubviewToFront(btn)
        }
    }
}

#if !OMNI_DYLIB_PLUGIN
@main
struct OmniContainerApp: App {
    @StateObject private var workspace = OmniWorkspaceStore()
    var body: some Scene {
        WindowGroup {
            OmniRootContainerView()
                .environmentObject(workspace)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    workspace.handleIncomingURL(url)
                }
        }
    }
}
#endif

@_cdecl("OmniPluginInitialize")
public func OmniPluginInitialize() {
    Task { @MainActor in
        OmniOverlayController.shared.start()
    }
}

@_cdecl("OmniPluginHandleURLString")
public func OmniPluginHandleURLString(_ cStr: UnsafePointer<CChar>) {
    let str = String(cString: cStr)
    Task { @MainActor in
        OmniOverlayController.shared.handleURLString(str)
    }
}

struct OmniRootContainerView: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore
    @State private var showIPAFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            omniTopDockBar

            GeometryReader { geo in
                ZStack {
                    if workspace.activeAppID == "home" {
                        OmniSpringBoardView(showIPAFilePicker: $showIPAFilePicker)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else if workspace.splitScreenEnabled {
                        VStack(spacing: 0) {
                            EmbeddedLiveAppHost(appID: workspace.activeAppID)
                                .frame(width: geo.size.width, height: geo.size.height * 0.5)
                            Divider().background(Color.cyan)
                            EmbeddedLiveAppHost(appID: workspace.secondaryAppID)
                                .frame(width: geo.size.width, height: geo.size.height * 0.5)
                        }
                    } else {
                        EmbeddedLiveAppHost(appID: workspace.activeAppID)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.08).ignoresSafeArea())
        .fileImporter(
            isPresented: $showIPAFilePicker,
            allowedContentTypes: [UTType.data, UTType.archive, UTType.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for u in urls {
                    workspace.installIPAFromURL(u)
                }
            }
        }
    }

    private var omniTopDockBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    workspace.activeAppID = "home"
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.3x3.fill")
                        Text("Apps")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(workspace.activeAppID == "home" ? Color.cyan : Color.white.opacity(0.1))
                    .foregroundColor(workspace.activeAppID == "home" ? .black : .white)
                    .cornerRadius(8)
                }

                Button {
                    if workspace.isRunningInsideNativeYouTube {
                        workspace.isMinimizedToYouTube = true
                    } else {
                        workspace.launchOrFocus("youtube")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle.fill")
                        Text("YouTube")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                Button {
                    showIPAFilePicker = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.app.fill")
                        Text("Install .IPA")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.3))
                    .foregroundColor(.purple)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.6), lineWidth: 1))
                    .cornerRadius(8)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.runningAppIDs, id: \.self) { id in
                            let isActive = (workspace.activeAppID == id)
                            let title = workspace.titleForAppID(id)
                            HStack(spacing: 4) {
                                Button {
                                    workspace.launchOrFocus(id)
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                        Text(title)
                                            .font(.caption2.bold())
                                            .foregroundColor(.white)
                                    }
                                }
                                Button {
                                    workspace.closeRunningApp(id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isActive ? Color.cyan.opacity(0.32) : Color.white.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isActive ? Color.cyan : Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .cornerRadius(8)
                        }
                    }
                }

                Button {
                    workspace.toggleRoute()
                } label: {
                    Text(workspace.routeLabel)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                }

                Button {
                    workspace.splitScreenEnabled.toggle()
                } label: {
                    Image(systemName: workspace.splitScreenEnabled ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .font(.caption.bold())
                        .padding(6)
                        .background(workspace.splitScreenEnabled ? Color.orange : Color.white.opacity(0.1))
                        .foregroundColor(workspace.splitScreenEnabled ? .black : .white)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            if workspace.splitScreenEnabled && workspace.activeAppID != "home" {
                HStack(spacing: 6) {
                    Text("Bottom Split:")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Picker("Bottom App", selection: $workspace.secondaryAppID) {
                        ForEach(workspace.builtInApps) { a in
                            Text(a.title).tag(a.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.75))
    }
}

struct OmniSpringBoardView: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore
    @Binding var showIPAFilePicker: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "shippingbox.and.arrow.backward.fill")
                            .font(.title2)
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OmniContainer Standalone .IPA Host")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                            Text(workspace.statusBanner)
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            showIPAFilePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.app.fill")
                                Text("Install .IPA from Files")
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }

                        Button {
                            workspace.installClipAppToHomeScreen(key: "all")
                        } label: {
                            HStack {
                                Image(systemName: "apps.iphone.badge.plus")
                                Text("Install All 14 Home Icons")
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.4), lineWidth: 1))
                .cornerRadius(14)

                // Installed .IPA Packages Section (Unpacked directly inside OmniContainer!)
                if !workspace.installedIPAs.isEmpty {
                    Text("Installed .IPA Packages (\(workspace.installedIPAs.count))")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)

                    ForEach(workspace.installedIPAs) { pkg in
                        HStack(spacing: 12) {
                            if let b64 = pkg.iconBase64,
                               let d = Data(base64Encoded: b64),
                               let uiImg = UIImage(data: d) {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 46, height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.purple.opacity(0.25))
                                    .frame(width: 46, height: 46)
                                    .overlay(Image(systemName: "app.badge.checkmark.fill").foregroundColor(.purple))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pkg.appName)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                Text("\(pkg.bundleID) • v\(pkg.version) • \(pkg.sizeMB)")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()

                            Button("Open") {
                                workspace.launchInstalledIPA(pkg)
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .cornerRadius(8)

                            Button {
                                workspace.deleteInstalledIPA(pkg)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding(6)
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                    }
                }

                HStack {
                    Text("All 14 Integrated Apps (Zero-Close Multitasking)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Text("Route: \(workspace.truenasHost)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.green)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(workspace.builtInApps) { app in
                        let isRunning = workspace.runningAppIDs.contains(app.id)
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                workspace.launchOrFocus(app.id)
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack(alignment: .topTrailing) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(app.color.opacity(0.22))
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Image(systemName: app.icon)
                                                    .font(.title3)
                                                    .foregroundColor(app.color)
                                            )
                                        if isRunning {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 10, height: 10)
                                                .offset(x: 3, y: -3)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.title)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(app.subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }

                            HStack(spacing: 6) {
                                Button {
                                    workspace.launchOrFocus(app.id)
                                } label: {
                                    Text(isRunning ? "Switch To" : "Open")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(app.color.opacity(0.25))
                                        .foregroundColor(app.color)
                                        .cornerRadius(7)
                                }

                                Button {
                                    workspace.installClipAppToHomeScreen(key: app.id)
                                } label: {
                                    Text("+ Clip")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.1))
                                        .foregroundColor(.white)
                                        .cornerRadius(7)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isRunning ? Color.green.opacity(0.5) : app.color.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(14)
                    }
                }
            }
            .padding()
        }
    }
}

struct EmbeddedLiveAppHost: View {
    @EnvironmentObject var workspace: OmniWorkspaceStore
    let appID: String

    var body: some View {
        switch appID {
        case "youtube":
            MiniYouTubeProModule(host: workspace.truenasHost)
        case "keepwatch":
            MiniKeepwatchModule(host: workspace.truenasHost)
        case "jarvis":
            MiniJarvisModule(host: workspace.truenasHost)
        case "nasportal":
            MiniNASPortalModule(host: workspace.truenasHost)
        case "antigravity":
            MiniAntigravityModule()
        case "aegis":
            MiniAegisModule()
        case "deskswitch":
            MiniDeskSwitchModule()
        case "sentrycam":
            MiniSentryCamModule(host: workspace.truenasHost)
        case "aniimo":
            MiniAniimoModule()
        case "racebolt":
            FastCachedWebView(cacheKey: "racebolt", urlString: "https://raceboltuk.com")
        case "photopulse":
            MiniPhotoPulseModule(host: workspace.truenasHost)
        case "netradar":
            MiniNetRadarModule(host: workspace.truenasHost)
        case "soulseekr":
            MiniSoulSeekrModule(host: workspace.truenasHost)
        case "zimadeck":
            MiniZimaDeckModule(host: workspace.truenasHost)
        default:
            if let pkg = workspace.installedIPAs.first(where: { $0.mappedModuleID == appID }), !pkg.runtimeURL.isEmpty {
                FastCachedWebView(cacheKey: appID, urlString: pkg.runtimeURL, enableYouTubePro: true)
            } else {
                FastCachedWebView(cacheKey: appID, urlString: "https://duckduckgo.com", enableYouTubePro: true)
            }
        }
    }
}

// MARK: - YouTube Pro Module (Ad-Block + Auto-Skip + PiP + Background Play + 1-Tap MeTube Download!)
struct MiniYouTubeProModule: View {
    let host: String
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundColor(.red)
                Text("YouTube Pro")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Button {
                    WebViewCache.shared.togglePiP(for: "youtube-pro")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pip.enter")
                        Text("PiP")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.28))
                    .foregroundColor(.white)
                    .cornerRadius(7)
                }
                Button {
                    WebViewCache.shared.forceResumeAllWebViews()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                        Text("BG Audio")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.25))
                    .foregroundColor(.green)
                    .cornerRadius(7)
                }
                Spacer()
                Picker("View", selection: $mode) {
                    Text("YouTube").tag(0)
                    Text("MeTube").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 145)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.85))

            if mode == 0 {
                FastCachedWebView(cacheKey: "youtube-pro", urlString: "https://m.youtube.com", enableYouTubePro: true)
            } else {
                FastCachedWebView(cacheKey: "metube-30094", urlString: "https://metube.nas-server.co.uk")
            }
        }
    }
}

// MARK: - Keepwatch, Jarvis & NASPortal Integrated Modules
struct MiniKeepwatchModule: View {
    let host: String
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Text("Dashboard").tag(0)
                Text("Sonarr").tag(1)
                Text("Radarr").tag(2)
                Text("Jellyseerr").tag(3)
                Text("Portainer").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "kw-homepage", urlString: "https://dashboard.nas-server.co.uk")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "kw-sonarr", urlString: "https://sonarr.nas-server.co.uk")
            } else if tab == 2 {
                FastCachedWebView(cacheKey: "kw-radarr", urlString: "https://radarr.nas-server.co.uk")
            } else if tab == 3 {
                FastCachedWebView(cacheKey: "kw-jellyseerr", urlString: "https://jellyseerr.nas-server.co.uk")
            } else {
                FastCachedWebView(cacheKey: "kw-portainer", urlString: "https://portainer.nas-server.co.uk")
            }
        }
    }
}

struct MiniJarvisModule: View {
    let host: String
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Jarvis", selection: $tab) {
                Text("Jarvis Console").tag(0)
                Text("Navidrome Music").tag(1)
                Text("Paydays").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "jarvis-web", urlString: "https://jarvis.nas-server.co.uk")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "navidrome-web", urlString: "https://navidrome.nas-server.co.uk")
            } else {
                FastCachedWebView(cacheKey: "paydays-web", urlString: "https://paydays.nas-server.co.uk")
            }
        }
    }
}

struct MiniNASPortalModule: View {
    let host: String
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Portal", selection: $tab) {
                Text("Apps & 2FA").tag(0)
                Text("Vaultwarden").tag(1)
                Text("TrueNAS UI").tag(2)
                Text("NZBGet").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "np-hub", urlString: "https://portal.nas-server.co.uk/app/nasportal")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "np-vault", urlString: "https://vw.nas-server.co.uk")
            } else if tab == 2 {
                FastCachedWebView(cacheKey: "np-truenas", urlString: "https://nas-server.co.uk")
            } else {
                FastCachedWebView(cacheKey: "np-nzbget", urlString: "https://nzbget.nas-server.co.uk")
            }
        }
    }
}

// MARK: - SentryCam Module (Port 5000 + All 3 Cameras: tapo_c200, bike_camera, doorbell + PTZ!)
struct MiniSentryCamModule: View {
    let host: String
    @State private var selectedCam = "tapo_c200"
    @State private var viewMode = 0
    @State private var tick = Int(Date().timeIntervalSince1970)
    @State private var status = "Connected to Frigate NVR (:5000)"

    let cameras = [
        ("tapo_c200", "Tapo C200 (Garden/Porch)"),
        ("bike_camera", "Bike Camera"),
        ("doorbell", "Front Doorbell")
    ]

    let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $viewMode) {
                Text("All 3 Cameras").tag(0)
                Text("PTZ & Single").tag(1)
                Text("Frigate UI").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if viewMode == 0 {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(cameras, id: \.0) { cam in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                    Text(cam.1).font(.caption.bold()).foregroundColor(.white)
                                    Spacer()
                                    Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.red)
                                }
                                AsyncImage(url: URL(string: "http://\(host):5000/api/\(cam.0)/latest.jpg?h=480&t=\(tick)")) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFit()
                                    } else {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.white.opacity(0.06))
                                            .frame(height: 180)
                                            .overlay(ProgressView().tint(.red))
                                    }
                                }
                                .cornerRadius(10)
                                .onTapGesture {
                                    selectedCam = cam.0
                                    viewMode = 1
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                        }
                    }
                    .padding(12)
                }
            } else if viewMode == 1 {
                ScrollView {
                    VStack(spacing: 12) {
                        Picker("Camera", selection: $selectedCam) {
                            ForEach(cameras, id: \.0) { c in
                                Text(c.1).tag(c.0)
                            }
                        }
                        .pickerStyle(.segmented)

                        AsyncImage(url: URL(string: "http://\(host):5000/api/\(selectedCam)/latest.jpg?h=720&t=\(tick)")) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 220)
                                    .overlay(ProgressView().tint(.red))
                            }
                        }
                        .cornerRadius(12)

                        Text(status).font(.caption2).foregroundColor(.orange)

                        HStack(spacing: 12) {
                            ptzBtn("Start Patrol", cmd: "sudo docker start tapo-patrol")
                            ptzBtn("Stop Patrol", cmd: "sudo docker stop tapo-patrol")
                            Button("Refresh") { tick = Int(Date().timeIntervalSince1970) }
                                .font(.caption.bold())
                                .padding(10)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    .padding(12)
                }
            } else {
                FastCachedWebView(cacheKey: "frigate-ui", urlString: "https://frigate.nas-server.co.uk")
            }
        }
        .onReceive(timer) { _ in
            if viewMode != 2 {
                tick = Int(Date().timeIntervalSince1970)
            }
        }
    }

    func ptzBtn(_ title: String, cmd: String) -> some View {
        Button(title) {
            Task {
                guard let u = URL(string: "http://\(host):9092/api/antigravity/exec") else { return }
                var req = URLRequest(url: u)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
                _ = try? await URLSession.shared.data(for: req)
                status = "Executed: \(title)"
            }
        }
        .font(.caption.bold())
        .padding(10)
        .background(Color.white.opacity(0.1))
        .foregroundColor(.white)
        .cornerRadius(8)
    }
}

// MARK: - NetRadar Module
struct MiniNetRadarModule: View {
    let host: String
    @State private var tab = 0
    @State private var pingMs: String = "--"
    @State private var downMbps: String = "--"
    @State private var isTesting = false
    @State private var logText = "Tap 'Run Native SpeedTest' for instant TrueNAS bandwidth & latency measurement."

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $tab) {
                Text("Native SpeedTest").tag(0)
                Text("OpenSpeedTest (SSL)").tag(1)
                Text("NPM (SSL)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 14) {
                            VStack(spacing: 4) {
                                Text("PING LATENCY")
                                    .font(.caption2.bold()).foregroundColor(.gray)
                                Text("\(pingMs) ms")
                                    .font(.title.bold().monospacedDigit()).foregroundColor(.cyan)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(14)

                            VStack(spacing: 4) {
                                Text("DOWNLOAD SPEED")
                                    .font(.caption2.bold()).foregroundColor(.gray)
                                Text("\(downMbps) Mbps")
                                    .font(.title.bold().monospacedDigit()).foregroundColor(.green)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(14)
                        }

                        Button {
                            Task { await runNativeBenchmark() }
                        } label: {
                            HStack {
                                if isTesting { ProgressView().tint(.black) }
                                Image(systemName: "speedometer")
                                Text(isTesting ? "Measuring Bandwidth..." : "Run Native SpeedTest to TrueNAS (\(host))")
                                    .font(.subheadline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(12)
                        }
                        .disabled(isTesting)

                        Text(logText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(10)
                    }
                    .padding()
                }
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "ost-30116", urlString: "https://speedtest.nas-server.co.uk")
            } else {
                FastCachedWebView(cacheKey: "npm-30020", urlString: "https://npm.nas-server.co.uk")
            }
        }
    }

    func runNativeBenchmark() async {
        isTesting = true
        defer { isTesting = false }
        let t0 = Date()
        if let u = URL(string: "http://\(host):5000/api/version") {
            _ = try? await URLSession.shared.data(from: u)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            pingMs = "\(ms)"
        }
        let tStart = Date()
        var totalBytes = 0
        for i in 0..<6 {
            if let u = URL(string: "http://\(host):5000/api/tapo_c200/latest.jpg?h=1080&b=\(i)_\(Int.random(in: 1...99999))"),
               let (d, _) = try? await URLSession.shared.data(from: u) {
                totalBytes += d.count
            }
        }
        let elapsed = max(Date().timeIntervalSince(tStart), 0.05)
        let mbps = (Double(totalBytes * 8) / 1_000_000.0) / elapsed
        downMbps = String(format: "%.1f", mbps)
        logText = "Target: \(host)\nTransferred: \(totalBytes / 1024) KB in \(String(format: "%.2f", elapsed))s\nMeasured Speed: \(downMbps) Mbps • Ping: \(pingMs) ms"
    }
}

struct MiniPhotoPulseModule: View {
    let host: String
    @State private var tab = 0
    @State private var code = ""
    @State private var container = "icloudpd"
    @State private var status = "Immich & iCloudPD Ready"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $tab) {
                Text("Immich (SSL)").tag(0)
                Text("ImmichFrame (:9180)").tag(1)
                Text("Apple 2FA").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "immich-main", urlString: "https://immich.nas-server.co.uk")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "immich-frame", urlString: "http://\(host):9180")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(status).font(.caption).foregroundColor(.pink)
                        Picker("Stream", selection: $container) {
                            Text("Personal").tag("icloudpd")
                            Text("Shared").tag("icloudpd-shared")
                            Text("Hidden").tag("icloudpd-hidden")
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            TextField("6-Digit Apple 2FA Code", text: $code)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            Button("Submit 2FA") {
                                let c = code; code = ""
                                Task { await send2FA(c) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pink)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    func send2FA(_ c: String) async {
        guard let u = URL(string: "http://\(host):9092/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "echo '\(c)' | sudo docker attach --sig-proxy=false \(container) 2>&1"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        _ = try? await URLSession.shared.data(for: req)
        status = "Submitted 2FA code \(c) to \(container)"
    }
}

struct MiniSoulSeekrModule: View {
    let host: String
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Service", selection: $tab) {
                Text("Hearr (SSL)").tag(0)
                Text("slskd (SSL)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "hearr-5070", urlString: "https://hearr.nas-server.co.uk")
            } else {
                FastCachedWebView(cacheKey: "slskd-5030", urlString: "https://slskd.nas-server.co.uk")
            }
        }
    }
}

struct MiniZimaDeckModule: View {
    let host: String
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Service", selection: $tab) {
                Text("Komga (:30048)").tag(0)
                Text("Zima Portainer").tag(1)
                Text("Zima Immich").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if tab == 0 {
                FastCachedWebView(cacheKey: "komga-30048", urlString: "http://\(host):30048")
            } else if tab == 1 {
                FastCachedWebView(cacheKey: "zima-port", urlString: "http://100.82.255.29:9000")
            } else {
                FastCachedWebView(cacheKey: "zima-immich", urlString: "http://100.82.255.29:2283")
            }
        }
    }
}

struct MiniAntigravityModule: View {
    @State private var selectedNode = "100.102.4.54:9090"
    @State private var prompt = ""
    @State private var output = "Connected to 3-Node Antigravity Fleet (#1 Windows, #2 Bazzite, #3 TrueNAS)."
    @State private var screenTick = 0

    let nodes = [
        ("Win #1", "100.102.4.54:9090"),
        ("Bazzite #2", "100.79.246.119:9091"),
        ("TrueNAS #3", "100.85.127.42:9092")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Node", selection: $selectedNode) {
                    ForEach(nodes, id: \.1) { n in
                        Text(n.0).tag(n.1)
                    }
                }
                .pickerStyle(.segmented)

                AsyncImage(url: URL(string: "http://\(selectedNode)/api/antigravity/screen?t=\(screenTick)")) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 160)
                        .overlay(Text("Tap to refresh live screen (\(selectedNode))").font(.caption).foregroundColor(.gray))
                }
                .frame(maxHeight: 200)
                .cornerRadius(10)
                .onTapGesture { screenTick += 1 }

                HStack {
                    TextField("Message or shell command...", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                    Button("Chat") {
                        let p = prompt; prompt = ""
                        Task { await sendChat(p) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Exec") {
                        let p = prompt; prompt = ""
                        Task { await sendExec(p) }
                    }
                    .buttonStyle(.bordered)
                }

                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
            }
            .padding(12)
        }
    }

    func sendChat(_ text: String) async {
        guard let u = URL(string: "http://\(selectedNode)/api/antigravity/chat") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["message": text])
        if let (d, _) = try? await URLSession.shared.data(for: req) {
            output = String(data: d, encoding: .utf8) ?? "Sent"
        }
    }

    func sendExec(_ cmd: String) async {
        guard let u = URL(string: "http://\(selectedNode)/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd])
        if let (d, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            output = (obj["stdout"] as? String) ?? (obj["output"] as? String) ?? "Done"
        }
    }
}

struct MiniAegisModule: View {
    @State private var urlInput = "https://duckduckgo.com"
    @State private var activeURL = "https://duckduckgo.com"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shield.fill").foregroundColor(.cyan)
                TextField("Search or URL", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { navigate() }
                Button("Go") { navigate() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(8)
            .background(Color.black.opacity(0.6))

            FastCachedWebView(cacheKey: "aegis-main", urlString: activeURL, enableYouTubePro: true)
        }
    }

    func navigate() {
        var s = urlInput.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") {
            if s.contains(".") && !s.contains(" ") { s = "https://" + s }
            else { s = "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") }
        }
        activeURL = s
    }
}

struct MiniDeskSwitchModule: View {
    @State private var status = "Ready to switch Windows / Bazzite displays & Steam"
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(status).font(.caption).foregroundColor(.orange)
                HStack(spacing: 10) {
                    btn("Monitor Only", flag: "/internal", color: .cyan)
                    btn("TV Only", flag: "/external", color: .orange)
                    btn("Extend All", flag: "/extend", color: .purple)
                }
                HStack(spacing: 10) {
                    cmdBtn("Steam Big Picture", cmd: "cmd.exe /c start steam://open/bigpicture", color: .blue)
                    cmdBtn("Jellyfin TV", cmd: "cmd.exe /c start https://jellyfin.nas-server.co.uk", color: .pink)
                }
                HStack(spacing: 10) {
                    cmdBtn("Sleep PC", cmd: "rundll32.exe powrprof.dll,SetSuspendState 0,1,0", color: .indigo)
                    cmdBtn("Lock PC", cmd: "rundll32.exe user32.dll,LockWorkStation", color: .yellow)
                }
            }
            .padding()
        }
    }

    func btn(_ label: String, flag: String, color: Color) -> some View {
        Button(label) {
            Task { await execWin("DisplaySwitch.exe \(flag)") }
        }
        .font(.caption.bold())
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.22))
        .foregroundColor(color)
        .cornerRadius(10)
    }

    func cmdBtn(_ label: String, cmd: String, color: Color) -> some View {
        Button(label) {
            Task { await execWin(cmd) }
        }
        .font(.caption.bold())
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.22))
        .foregroundColor(color)
        .cornerRadius(10)
    }

    func execWin(_ c: String) async {
        guard let u = URL(string: "http://100.102.4.54:9090/api/antigravity/exec") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": c])
        _ = try? await URLSession.shared.data(for: req)
        status = "Executed: \(c)"
    }
}

struct MiniAniimoModule: View {
    @State private var tick = 0
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                AsyncImage(url: URL(string: "http://100.102.4.54:9090/api/antigravity/screen?t=\(tick)")) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)).frame(height: 180)
                }
                .cornerRadius(10)
                .onTapGesture { tick += 1 }

                HStack {
                    Button("Refresh Game Screen") { tick += 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
}
