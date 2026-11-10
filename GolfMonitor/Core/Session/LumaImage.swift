import CoreGraphics
import CoreVideo
import Foundation

/// Read-only access to a frame's brightness (0–255), independent of the
/// pixel format. The scene monitor only needs a handful of samples per
/// frame, so this deliberately offers point sampling rather than copies.
protocol LumaImage {
    var width: Int { get }
    var height: Int { get }
    func luma(x: Int, y: Int) -> UInt8
}

extension LumaImage {
    /// Coarse grid of `columns` × `rows` samples covering the frame.
    func grid(columns: Int, rows: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(columns * rows)
        for r in 0..<rows {
            let y = min(height - 1, (2 * r + 1) * height / (2 * rows))
            for c in 0..<columns {
                let x = min(width - 1, (2 * c + 1) * width / (2 * columns))
                out.append(luma(x: x, y: y))
            }
        }
        return out
    }

    /// Samples on a `steps` × `steps` lattice inside the disk of `radius`
    /// around `center`. Points outside the frame are skipped, so callers get
    /// the same count only for disks fully inside the frame.
    func disk(center: CGPoint, radius: Double, steps: Int = 7) -> [UInt8] {
        guard radius > 0, steps > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(steps * steps)
        for j in 0..<steps {
            for i in 0..<steps {
                let dx = (Double(i) + 0.5) / Double(steps) * 2 - 1
                let dy = (Double(j) + 0.5) / Double(steps) * 2 - 1
                guard dx * dx + dy * dy <= 1 else { continue }
                let x = Int((Double(center.x) + dx * radius).rounded())
                let y = Int((Double(center.y) + dy * radius).rounded())
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                out.append(luma(x: x, y: y))
            }
        }
        return out
    }
}

/// Mean absolute difference of two equally long sample vectors, 0...1.
func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Float {
    guard !a.isEmpty, a.count == b.count else { return a.isEmpty && b.isEmpty ? 0 : 1 }
    var total = 0
    for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
    return Float(total) / Float(a.count * 255)
}

/// Brightness view of a locked CVPixelBuffer. Supports bi-planar YUV (the
/// camera's 420f/420v — the Y plane IS luma) and 32BGRA.
struct PixelBufferLuma: LumaImage {
    let width: Int
    let height: Int
    private let base: UnsafePointer<UInt8>
    private let rowBytes: Int
    private let isBGRA: Bool

    /// Locks `buffer`, runs `body`, unlocks. Returns nil for unsupported formats.
    static func with<R>(_ buffer: CVPixelBuffer, _ body: (PixelBufferLuma) -> R) -> R? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let image: PixelBufferLuma?
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let p = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            image = PixelBufferLuma(width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                                    height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                                    base: UnsafePointer(p.assumingMemoryBound(to: UInt8.self)),
                                    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                    isBGRA: false)
        case kCVPixelFormatType_32BGRA:
            guard let p = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            image = PixelBufferLuma(width: CVPixelBufferGetWidth(buffer),
                                    height: CVPixelBufferGetHeight(buffer),
                                    base: UnsafePointer(p.assumingMemoryBound(to: UInt8.self)),
                                    rowBytes: CVPixelBufferGetBytesPerRow(buffer),
                                    isBGRA: true)
        default:
            image = nil
        }
        return image.map(body)
    }

    func luma(x: Int, y: Int) -> UInt8 {
        let row = base.advanced(by: y * rowBytes)
        guard isBGRA else { return row[x] }
        let p = row.advanced(by: x * 4)
        return UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
    }
}

/// In-memory luma image (tests, synthetic scenes).
struct ArrayLuma: LumaImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: UInt8 = 0) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: fill, count: width * height)
    }

    func luma(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    mutating func fillCircle(center: CGPoint, radius: Double, value: UInt8) {
        let r2 = radius * radius
        let x0 = max(0, Int(Double(center.x) - radius)), x1 = min(width - 1, Int(Double(center.x) + radius))
        let y0 = max(0, Int(Double(center.y) - radius)), y1 = min(height - 1, Int(Double(center.y) + radius))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) - Double(center.x), dy = Double(y) - Double(center.y)
                if dx * dx + dy * dy <= r2 { pixels[y * width + x] = value }
            }
        }
    }

    mutating func fillRect(_ rect: CGRect, value: UInt8) {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { for x in x0..<x1 { pixels[y * width + x] = value } }
    }
}
