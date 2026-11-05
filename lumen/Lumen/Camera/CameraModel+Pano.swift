import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Panorama: collect a sweep of frames from the live preview, then stitch them into one wide photo on the NAS.
extension CameraModel {
    /// Starts collecting frames. Needs the NAS upscaler set up (that's where stitching runs).
    func startPano() {
        guard UpscalerSettings.load().isConfigured else {
            message = "Set up your NAS in the editor's AI tab first — that's where panoramas are stitched."
            return
        }
        panoStitchTask?.cancel()
        panoStitchTask = nil
        panoStatus = nil
        panoResult = nil
        lastPanoGrab = .distantPast
        videoQueue.async { self.panoFrames = [] }
        panoFrameCount = 0
        panoActive = true
    }

    func stopPano() {
        guard panoActive else { return }
        panoActive = false
        videoQueue.async {
            let frames = self.panoFrames
            self.panoFrames = []
            DispatchQueue.main.async { self.stitchPano(frames) }
        }
    }

    func cancelPano() {
        panoActive = false
        panoStitchTask?.cancel()
        panoStitchTask = nil
        panoStatus = nil
        videoQueue.async { self.panoFrames = [] }
        panoFrameCount = 0
    }

    /// Called on the video queue for each preview frame while a panorama is being captured.
    func grabPanoFrame(_ buffer: CVPixelBuffer, rotation angle: CGFloat) {
        let now = Date()
        guard now.timeIntervalSince(lastPanoGrab) >= 0.5, panoFrames.count < panoMaxFrames else { return }
        lastPanoGrab = now
        guard let jpeg = panoJPEG(buffer, rotation: angle) else { return }
        panoFrames.append(jpeg)
        let count = panoFrames.count
        DispatchQueue.main.async {
            self.panoFrameCount = count
            if count >= self.panoMaxFrames { self.stopPano() }
        }
    }

    private func panoJPEG(_ buffer: CVPixelBuffer, rotation angle: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let orientation: Int32 = angle == 90 ? 6 : (angle == 270 ? 8 : (angle == 180 ? 3 : 1))
        image = image.oriented(forExifOrientation: orientation)
        let longSide = max(image.extent.width, image.extent.height)
        let scale = longSide > 1600 ? 1600 / longSide : 1
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cg = panoContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    /// Uploads the captured frames to the NAS and follows the stitch job to its result.
    private func stitchPano(_ frames: [Data]) {
        guard frames.count >= 2 else {
            message = "Pan a little more next time — I need at least a couple of frames to stitch."
            panoFrameCount = 0
            return
        }
        panoStatus = "Stitching \(frames.count) frames on your NAS…"
        let client = UpscaleClient(settings: UpscalerSettings.load())
        panoStitchTask = Task { @MainActor in
            defer { panoFrameCount = 0 }
            do {
                let job = try await client.startPano(images: frames)
                var status = try await client.status(job)
                while status.state == "queued" || status.state == "working" {
                    try Task.checkCancellation()
                    panoStatus = status.state == "queued"
                        ? "Waiting for the NAS…"
                        : "Stitching on your NAS… \(Int(status.progress * 100))%"
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    status = try await client.status(job)
                }
                guard status.state == "done" else {
                    throw UpscaleError.server(status.error ?? "The panorama couldn't be stitched. Try panning more slowly with more overlap.")
                }
                let data = try await client.result(job)
                panoStatus = nil
                panoResult = data
            } catch is CancellationError {
                panoStatus = nil
            } catch {
                panoStatus = nil
                message = error.localizedDescription
            }
        }
    }
}
