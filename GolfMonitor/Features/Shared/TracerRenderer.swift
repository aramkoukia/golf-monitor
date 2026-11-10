import AVFoundation
import UIKit

/// Renders a still for sharing and lists: the frame just after impact with
/// the measured ball path drawn as a glowing Plasma tracer.
enum TracerRenderer {
    static func render(videoURL: URL, analysis: SwingAnalysis) async -> UIImage? {
        let impact = analysis.impactTime ?? analysis.marker(.impact)?.t
        let frameTime = impact.map { $0 + 0.05 } ?? analysis.duration / 2
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        guard let cg = await generator.frameImage(at: CMTime(seconds: frameTime, preferredTimescale: 6000)) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        let points = analysis.ballTrack.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            guard points.count >= 2 else { return }
            let c = context.cgContext
            let path = CGMutablePath()
            path.addLines(between: points)
            // Extend the fitted line a little beyond the last tracked point.
            if let a = points.first, let b = points.last {
                path.addLine(to: CGPoint(x: b.x + (b.x - a.x) * 0.6, y: b.y + (b.y - a.y) * 0.6))
            }
            let width = max(4, size.width / 150)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.setBlendMode(.plusLighter)
            c.setShadow(offset: .zero, blur: width * 3, color: UIColor(red: 1, green: 0.35, blue: 0.12, alpha: 1).cgColor)
            c.setStrokeColor(UIColor(red: 1, green: 0.35, blue: 0.12, alpha: 1).cgColor)
            c.setLineWidth(width)
            c.addPath(path)
            c.strokePath()
            c.setShadow(offset: .zero, blur: 0)
            c.setStrokeColor(UIColor(red: 1, green: 0.91, blue: 0.69, alpha: 1).cgColor)
            c.setLineWidth(width * 0.35)
            c.addPath(path)
            c.strokePath()
            c.setBlendMode(.normal)
            if let address = points.first {
                let r = width * 2.2
                c.setStrokeColor(UIColor(red: 0.24, green: 0.96, blue: 0.65, alpha: 0.9).cgColor)
                c.setLineWidth(width * 0.4)
                c.strokeEllipse(in: CGRect(x: address.x - r, y: address.y - r, width: r * 2, height: r * 2))
            }
        }
    }
}
