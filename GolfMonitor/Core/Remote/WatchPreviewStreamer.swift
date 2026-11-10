import CoreImage
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

/// Turns camera frames into small JPEGs for the watch preview, a few times
/// a second and only while the watch holds a preview lease. One frame is in
/// flight at a time; the next is only encoded after the watch acknowledged
/// the previous one (or it timed out), so a slow Bluetooth link never backs
/// up the camera.
final class WatchPreviewStreamer: FrameConsumer {
    /// Seconds between frames (~4 fps).
    var interval: Double = 0.25
    /// Longest side of the JPEG in pixels.
    var maxDimension: CGFloat = 300
    var quality: CGFloat = 0.5

    /// Thread-safe check: should frames flow right now?
    var isActive: () -> Bool = { false }
    /// Delivers one encoded frame (on the encode queue). Call `delivered()`
    /// when the transport is done with it.
    var send: ((Data) -> Void)?

    private let encodeQueue = DispatchQueue(label: "golfmonitor.watch.preview", qos: .utility)
    private let copier = PixelBufferCopier()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var inFlightSince: Double?
    private var lastSent = -Double.infinity

    func consume(_ pixelBuffer: CVPixelBuffer, time: Double) {
        guard send != nil, isActive() else { return }
        let now = CACurrentMediaTime()
        let ready: Bool = lock.withLock {
            if let since = inFlightSince, now - since < 2 { return false }
            guard now - lastSent >= interval else { return false }
            inFlightSince = now
            lastSent = now
            return true
        }
        guard ready else { return }
        // Encode a private copy so the camera's buffer pool is never held up.
        guard let copy = copier.copy(pixelBuffer) else {
            delivered()
            return
        }
        encodeQueue.async { [weak self] in
            guard let self else { return }
            guard let data = self.encode(copy) else {
                self.delivered()
                return
            }
            self.send?(data)
        }
    }

    func delivered() {
        lock.withLock { inFlightSince = nil }
    }

    func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let scale = min(1, maxDimension / max(extent.width, extent.height, 1))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return context.jpegRepresentation(of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: options)
    }
}
