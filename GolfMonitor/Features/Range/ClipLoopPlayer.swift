import AVFoundation
import SwiftUI

/// Loops the impact window of a shot clip in super slow motion (240 fps
/// played at 1/8 speed) with the measured ball path drawn on top in sync —
/// the tracer grows as the ball flies.
struct ClipLoopPlayer: View {
    var url: URL
    var analysis: SwingAnalysis?
    /// Seconds around impact to loop.
    var before: Double = 0.7
    var after: Double = 0.9
    var rate: Float = 0.125

    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var observers: [Any] = []

    private var frameAspect: CGFloat {
        guard let a = analysis, a.frameHeight > 0 else { return 9.0 / 16.0 }
        return CGFloat(a.frameWidth) / CGFloat(a.frameHeight)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PlayerLayerView(player: player)
                if let analysis {
                    TracerOverlay(analysis: analysis, currentTime: currentTime,
                                  mapping: AspectFitMapping(viewSize: geo.size, frameAspect: frameAspect))
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .accessibilityLabel("Slow-motion replay of your shot")
    }

    private func start() {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        let impact = analysis?.impactTime ?? analysis?.marker(.impact)?.t
        let duration = analysis?.duration ?? 0
        let start = impact.map { max(0, $0 - before) } ?? 0
        let end = impact.map { min(duration > 0 ? duration : $0 + after, $0 + after) } ?? max(duration, 1)
        let startTime = CMTime(seconds: start, preferredTimescale: 6000)
        let endTime = CMTime(seconds: max(end, start + 0.2), preferredTimescale: 6000)
        let loop = player.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) { [player] in
            player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            player.rate = rate
        }
        let tick = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { time in
            currentTime = time.seconds
        }
        observers = [loop, tick]
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.rate = rate
        }
    }

    private func stop() {
        observers.forEach(player.removeTimeObserver)
        observers = []
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Plasma tracer for the ball track up to `currentTime` (post-impact only),
/// plus a ring on the ball at address.
struct TracerOverlay: View {
    var analysis: SwingAnalysis
    var currentTime: Double
    var mapping: AspectFitMapping
    var color: Color = Theme.Palette.plasma

    var body: some View {
        Canvas { context, _ in
            let impact = analysis.impactTime ?? 0
            let flight = analysis.ballTrack.filter { $0.t >= impact && $0.t <= currentTime }
            if let address = analysis.ballTrack.first(where: { $0.t <= impact }) ?? analysis.ballTrack.first {
                let p = mapping.point(CGPoint(x: address.x, y: address.y))
                let ring = Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
                context.stroke(ring, with: .color(Theme.Palette.ion.opacity(currentTime < impact ? 0.9 : 0.35)), lineWidth: 1.5)
            }
            if flight.count >= 2 {
                var path = Path()
                for (i, point) in flight.enumerated() {
                    let p = mapping.point(CGPoint(x: point.x, y: point.y))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                var glow = context
                glow.addFilter(.blur(radius: 6))
                glow.stroke(path, with: .color(color.opacity(0.9)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(.white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if let head = flight.last {
                let p = mapping.point(CGPoint(x: head.x, y: head.y))
                var bloom = context
                bloom.addFilter(.blur(radius: 5))
                bloom.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                           with: .color(color))
                let ring = Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
                context.stroke(ring, with: .color(color),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white))
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Bare AVPlayerLayer host (aspect-fit, no controls).
struct PlayerLayerView: UIViewRepresentable {
    var player: AVPlayer

    final class HostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.playerLayer.player = player
    }
}
