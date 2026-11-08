import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Remote viewfinder: serve the live preview to a browser on the same network, with a shutter button.
extension CameraModel {
    func startRemoteViewfinder() {
        guard remoteServer == nil else { return }
        let server = RemoteViewfinder()
        server.onShoot = { [weak self] in DispatchQueue.main.async { self?.capture() } }
        remoteServer = server
        server.start { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                if let url {
                    self.remoteAddress = url
                    self.remoteActive = true
                } else {
                    self.remoteServer = nil
                    self.message = "Couldn't start the remote viewfinder on this network."
                }
            }
        }
    }

    func stopRemoteViewfinder() {
        remoteServer?.stop()
        remoteServer = nil
        remoteActive = false
        remoteAddress = nil
    }

    func toggleRemoteViewfinder() {
        if remoteActive || remoteServer != nil { stopRemoteViewfinder() } else { startRemoteViewfinder() }
    }

    /// A small, low-quality JPEG of the preview frame for the MJPEG stream.
    func remoteFrameJPEG(_ buffer: CVPixelBuffer, rotation angle: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let orientation: Int32 = angle == 90 ? 6 : (angle == 270 ? 8 : (angle == 180 ? 3 : 1))
        image = image.oriented(forExifOrientation: orientation)
        let longSide = max(image.extent.width, image.extent.height)
        let scale = longSide > 720 ? 720 / longSide : 1
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cg = panoContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.5)
    }
}
