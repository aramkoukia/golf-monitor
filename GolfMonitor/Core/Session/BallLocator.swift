import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Finds stationary golf balls in a single upright frame.
protocol BallLocating: AnyObject {
    func candidates(in pixelBuffer: CVPixelBuffer) -> [BallCandidate]
}

/// On-device golf-ball finder: the bundled GolfDetector (fine-tuned YOLO,
/// Core ML) on native-resolution tiles, with the generic COCO "sports ball"
/// class as a fallback. Each detection's diameter is then re-measured from
/// the ball's bright disk, which is more precise than the box edge and is
/// what the pixels-per-metre calibration is derived from.
final class GolfBallLocator: BallLocating {
    private let minConfidence: Float
    private lazy var golfDetector = ObjectDetector(.golfDetector)
    private lazy var cocoDetector = ObjectDetector(.cocoDetector)

    init(minConfidence: Float = 0.25) {
        self.minConfidence = minConfidence
    }

    func candidates(in pixelBuffer: CVPixelBuffer) -> [BallCandidate] {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var detections: [Detection] = []
        if let golfDetector {
            detections = golfDetector.detectTiled(in: image, tile: 640, confidence: minConfidence)
                .filter { $0.label.localizedCaseInsensitiveContains("ball") || golfDetector.classNames.count <= 1 }
        }
        if detections.isEmpty, let cocoDetector {
            detections = cocoDetector.detectTiled(in: image, tile: 640, confidence: minConfidence, classes: [32])
        }
        let shortSide = Double(min(width, height))
        let measured = PixelBufferLuma.with(pixelBuffer) { luma in
            detections.compactMap { d -> BallCandidate? in
                let box = Double(d.diameter)
                // A real ball 0.7–6 m from the lens is 4–6 % of the frame at most;
                // anything bigger is a hat, a shoe or a knee.
                guard box >= 4, box <= shortSide * BallMeasure.maxDiameterFraction,
                      d.rect.width / max(d.rect.height, 1) < 1.6, d.rect.height / max(d.rect.width, 1) < 1.6,
                      BallMeasure.looksLikeBall(around: d.center, boxDiameter: box, in: luma) else { return nil }
                let diameter = BallMeasure.refinedDiameter(around: d.center, boxDiameter: box, in: luma)
                return BallCandidate(center: d.center, diameterPx: diameter, confidence: d.confidence)
            }
        } ?? []
        return BallMeasure.deduplicated(BallMeasure.rank(measured, frameWidth: width, frameHeight: height))
    }
}

enum BallMeasure {
    /// Largest plausible ball, as a fraction of the frame's short side.
    static let maxDiameterFraction = 0.065

    /// A golf ball is a bright disk on a darker surround (grass, mat, sky is
    /// excluded by the detector). Rejects pale blobs with no contrast.
    static func looksLikeBall(around center: CGPoint, boxDiameter: Double, in luma: LumaImage) -> Bool {
        let r = boxDiameter / 2
        let inner = luma.disk(center: center, radius: r * 0.45, steps: 5).map(Int.init).sorted()
        var ring: [Int] = []
        for k in 0..<16 {
            let a = Double(k) / 16 * 2 * .pi
            let x = Int(Double(center.x) + cos(a) * r * 1.5), y = Int(Double(center.y) + sin(a) * r * 1.5)
            guard x >= 0, y >= 0, x < luma.width, y < luma.height else { continue }
            ring.append(Int(luma.luma(x: x, y: y)))
        }
        guard inner.count >= 5, ring.count >= 8 else { return false }
        ring.sort()
        let innerMedian = inner[inner.count / 2]
        let ringMedian = ring[ring.count / 2]
        return innerMedian >= 110 && innerMedian - ringMedian >= 18
    }

    /// Re-measures a ball's diameter from its bright disk: pixels brighter
    /// than halfway between the ball's peak and the surrounding background,
    /// converted to the equivalent circle. Falls back to the detector box
    /// when the disk is ambiguous (low contrast, odd shape).
    static func refinedDiameter(around center: CGPoint, boxDiameter: Double, in luma: LumaImage) -> Double {
        let r = boxDiameter / 2
        let cx = Double(center.x), cy = Double(center.y)
        let x0 = max(0, Int(cx - r * 1.7)), x1 = min(luma.width - 1, Int(cx + r * 1.7))
        let y0 = max(0, Int(cy - r * 1.7)), y1 = min(luma.height - 1, Int(cy + r * 1.7))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return boxDiameter }

        var inner: [Int] = []
        var ring: [Int] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let d = hypot(Double(x) - cx, Double(y) - cy)
                let v = Int(luma.luma(x: x, y: y))
                if d <= r * 0.6 { inner.append(v) } else if d >= r * 1.25, d <= r * 1.7 { ring.append(v) }
            }
        }
        guard !inner.isEmpty, !ring.isEmpty else { return boxDiameter }
        inner.sort()
        ring.sort()
        let peak = inner[inner.count * 3 / 4]
        let background = ring[ring.count / 2]
        guard peak - background >= 25 else { return boxDiameter }
        let threshold = (peak + background) / 2

        var area = 0
        for y in y0...y1 {
            for x in x0...x1 where hypot(Double(x) - cx, Double(y) - cy) <= r * 1.25 {
                if Int(luma.luma(x: x, y: y)) >= threshold { area += 1 }
            }
        }
        let diameter = 2 * sqrt(Double(area) / .pi)
        guard diameter.isFinite, (boxDiameter * 0.6...boxDiameter * 1.35).contains(diameter) else { return boxDiameter }
        return diameter
    }

    /// Overlapping tiles report the same ball more than once: keep the first
    /// (best-ranked) of any candidates closer than ~one ball diameter.
    static func deduplicated(_ ranked: [BallCandidate]) -> [BallCandidate] {
        var kept: [BallCandidate] = []
        for c in ranked where !kept.contains(where: {
            hypot($0.center.x - c.center.x, $0.center.y - c.center.y) < CGFloat(0.9 * max($0.diameterPx, c.diameterPx))
        }) {
            kept.append(c)
        }
        return kept
    }

    /// Orders candidates so the likely "ball being hit" comes first: confident
    /// detections near the horizontal centre. (Several balls are watched at
    /// once, so a pile of balls next to the tee doesn't hide the teed one.)
    static func rank(_ candidates: [BallCandidate], frameWidth: Int, frameHeight: Int) -> [BallCandidate] {
        func score(_ c: BallCandidate) -> Double {
            let nx = Double(c.center.x) / Double(max(frameWidth, 1))
            let centrality = 1 - min(1, abs(nx - 0.5) * 1.4)
            return Double(c.confidence) * (0.5 + 0.5 * centrality)
        }
        return candidates.sorted { score($0) > score($1) }
    }
}
