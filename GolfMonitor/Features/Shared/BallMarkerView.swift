import SwiftUI

// MARK: - Detected-ball marker

/// Yellow ring drawn over the preview where Detect found the ball.
/// Maps frame pixels to view points using the same aspect-fill geometry
/// as the preview layer, so the ring lands on the ball at any size.
struct BallMarkerView: View {
    let ball: DetectedBall

    var body: some View {
        GeometryReader { geo in
            let fw = CGFloat(ball.frameWidth), fh = CGFloat(ball.frameHeight)
            let scale = max(geo.size.width / fw, geo.size.height / fh)
            let originX = (geo.size.width - fw * scale) / 2
            let originY = (geo.size.height - fh * scale) / 2
            let ring = CGFloat(ball.diameter) * scale + 18
            ZStack {
                Circle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: ring, height: ring)
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 5, height: 5)
            }
            .position(x: originX + ball.center.x * scale,
                      y: originY + ball.center.y * scale)
        }
    }
}
