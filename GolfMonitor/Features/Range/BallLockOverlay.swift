import SwiftUI

/// Targeting brackets drawn on every ball the scene monitor has locked:
/// Ion while the ball sits there, amber the moment it disappears. Purely
/// informational — there's no "detect ball" step; it just shows the app sees it.
struct BallLockOverlay: View {
    var snapshot: SceneSnapshot
    var isRecording: Bool

    var body: some View {
        GeometryReader { geo in
            let map = AspectFillMapping(viewSize: geo.size, frameAspect: snapshot.frameAspect)
            ForEach(snapshot.locks) { lock in
                let size = max(34, map.length(lock.diameter) * 2.6)
                LockReticle(isPresent: lock.isPresent, isRecording: isRecording)
                    .frame(width: size, height: size)
                    .position(map.point(lock.center))
                    .transition(.scale(scale: 1.8).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.snappy, value: snapshot.locks.map(\.id))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LockReticle: View {
    var isPresent: Bool
    var isRecording: Bool
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = isPresent ? Theme.Palette.ion : Theme.Palette.caution
        ZStack {
            CornerBrackets()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .shadow(color: color.opacity(0.8), radius: 6)
                .rotationEffect(.degrees(spin && !isRecording ? 90 : 0))
            Circle()
                .stroke(color.opacity(0.45), lineWidth: 1)
                .padding(10)
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6)) { spin = true }
        }
    }
}

/// Four L-shaped corners of a square.
struct CornerBrackets: Shape {
    var length: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        let l = min(rect.width, rect.height) * length
        var p = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (c, dx, dy) in corners {
            p.move(to: CGPoint(x: c.x + dx * l, y: c.y))
            p.addLine(to: c)
            p.addLine(to: CGPoint(x: c.x, y: c.y + dy * l))
        }
        return p
    }
}
