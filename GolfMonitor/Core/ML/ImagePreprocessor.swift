import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Geometry of a letterboxed crop: maps model-input pixels back to source
/// pixels. Model input is a square `side` × `side` image; the source region
/// `crop` (in source pixel coordinates, origin top-left) was scaled by
/// `scale` and centered with `padX`/`padY` of padding.
struct LetterboxTransform {
    var side: CGFloat
    var crop: CGRect
    var scale: CGFloat
    var padX: CGFloat
    var padY: CGFloat

    /// Model-input pixel point → source pixel point.
    func toSource(_ p: CGPoint) -> CGPoint {
        CGPoint(x: crop.minX + (p.x - padX) / scale,
                y: crop.minY + (p.y - padY) / scale)
    }

    /// Model-input pixel rect → source pixel rect.
    func toSource(_ r: CGRect) -> CGRect {
        let o = toSource(CGPoint(x: r.minX, y: r.minY))
        return CGRect(x: o.x, y: o.y, width: r.width / scale, height: r.height / scale)
    }
}

/// Renders a (cropped) region of a frame into a square, letterboxed BGRA
/// pixel buffer for Core ML. Done explicitly (instead of Vision's
/// imageCropAndScaleOption) so the coordinate mapping is exact and testable.
final class ImagePreprocessor {
    let side: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    init(side: Int = 640) {
        self.side = side
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// - Parameters:
    ///   - image: the full upright source frame.
    ///   - crop: region in source pixels (top-left origin); nil = whole frame.
    func letterbox(_ image: CIImage, crop: CGRect? = nil) -> (CVPixelBuffer, LetterboxTransform)? {
        let extent = image.extent
        let full = CGRect(x: 0, y: 0, width: extent.width, height: extent.height)
        let region = (crop ?? full).intersection(full).integral
        guard region.width >= 2, region.height >= 2, let pool else { return nil }

        let s = CGFloat(side)
        let scale = min(s / region.width, s / region.height)
        let padX = (s - region.width * scale) / 2
        let padY = (s - region.height * scale) / 2

        // CIImage space is bottom-left origin: flip the top-left crop rect.
        let ciCrop = CGRect(x: extent.minX + region.minX,
                            y: extent.minY + (extent.height - region.maxY),
                            width: region.width, height: region.height)
        let placed = image.cropped(to: ciCrop)
            .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: padX, y: padY))
        // Ultralytics letterbox gray (114) behind the image.
        let gray = CIImage(color: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255))
            .cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
        let composed = placed.composited(over: gray)

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { return nil }
        context.render(composed, to: buffer, bounds: CGRect(x: 0, y: 0, width: s, height: s),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (buffer, LetterboxTransform(side: s, crop: region, scale: scale, padX: padX, padY: padY))
    }
}
