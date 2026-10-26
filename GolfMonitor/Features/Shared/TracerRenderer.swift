import AVFoundation
import UIKit

// MARK: - Shot tracer renderer

/// Extracts a frame from the clip and draws the tracked ball trajectory over it.
enum TracerRenderer {

    static func makeTracerImage(videoURL: URL, tracking: TrackingResult) async -> UIImage? {
        guard !tracking.ballPoints.isEmpty else { return nil }
        // Show a frame a bit after impact so the ball trail is visible.
        let impactTime = tracking.impactBallIndex
            .flatMap { tracking.ballPoints.indices.contains($0) ? tracking.ballPoints[$0].time : nil } ?? 0
        let frameTime = min(impactTime + 0.12, tracking.ballPoints.last?.time ?? 0.5)
        guard let base = await frameImage(videoURL: videoURL, at: frameTime),
              let cg = base.cgImage
        else { return nil }

        let imgW = CGFloat(cg.width), imgH = CGFloat(cg.height)
        let sx = imgW / CGFloat(max(tracking.frameWidth, 1))
        let sy = imgH / CGFloat(max(tracking.frameHeight, 1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imgW, height: imgH), format: format)
        return renderer.image { _ in
            base.draw(in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
            guard let ctx = UIGraphicsGetCurrentContext() else { return }

            // Ball trail (yellow).
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(max(3, imgW / 320))
            ctx.setLineCap(.round)
            ctx.beginPath()
            for (i, p) in tracking.ballPoints.enumerated() {
                let q = CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy)
                if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
            }
            ctx.strokePath()

            // Impact marker (red dot).
            if let idx = tracking.impactBallIndex,
               tracking.ballPoints.indices.contains(idx) {
                let p = tracking.ballPoints[idx]
                let q = CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy)
                ctx.setFillColor(UIColor.systemRed.cgColor)
                let r = max(6, imgW / 160)
                ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2))
            }

            // Club trail pre-impact (cyan, thin).
            if tracking.clubPoints.count >= 2 {
                ctx.setStrokeColor(UIColor.systemCyan.cgColor)
                ctx.setLineWidth(max(2, imgW / 480))
                ctx.beginPath()
                for (i, p) in tracking.clubPoints.enumerated() {
                    let q = CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy)
                    if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
                }
                ctx.strokePath()
            }
        }
    }

    private static func frameImage(videoURL: URL, at seconds: Double) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = await generator.frameImage(at: time) else { return nil }
        return UIImage(cgImage: cg)
    }
}
