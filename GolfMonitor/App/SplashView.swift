import SwiftUI

/// Launch intro. It starts exactly where the launch screen leaves off (same
/// artwork, same aspect-fill layout), then the lock brackets snap onto the
/// ball, the shot's tracer flies across the sky and lands, and it fades into
/// the app. About 2 s; tap to skip; Reduce Motion gets a plain fade.
///
/// The artwork is rendered by `scripts/render-art.swift`; `Layout` mirrors
/// its `SplashGeometry`.
struct SplashView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var leaving = false

    enum Layout {
        static let image = CGSize(width: 1179, height: 2556)
        /// Fractions of the artwork (x of width, y of height).
        static let ball = CGPoint(x: 0.30, y: 0.712)
        /// Fraction of the artwork's width.
        static let ballRadius: CGFloat = 0.088
        static let control1 = CGPoint(x: 0.40, y: 0.26)
        static let control2 = CGPoint(x: 0.80, y: 0.24)
        static let landing = CGPoint(x: 0.90, y: 0.598)
    }

    /// Timeline, in seconds after the intro appears.
    enum Beat {
        static let lock = 0.15...0.5
        static let flight = 0.55...1.45
        static let landing = 1.45...1.95
        static let leave = 2.0
    }

    var body: some View {
        GeometryReader { geo in
            let map = ArtworkMap(image: Layout.image, view: geo.size)
            ZStack {
                Image("GolfMonitorSplash")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        Canvas { context, _ in
                            draw(in: &context, map: map, t: timeline.date.timeIntervalSince(start))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving ? 1.05 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("GolfMonitor")
        .accessibilityAddTraits(.isImage)
        .task {
            start = Date()
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.6 : Beat.leave))
            finish()
        }
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.35)) {
            leaving = true
        } completion: {
            onFinish()
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, map: ArtworkMap, t: Double) {
        let center = map.point(Layout.ball)
        let radius = map.length(Layout.ballRadius)
        let flight = Flight(p0: CGPoint(x: center.x + radius * 0.2, y: center.y - radius * 0.35),
                            c1: map.point(Layout.control1), c2: map.point(Layout.control2),
                            p3: map.point(Layout.landing))

        // The tracer leaves from behind the ball.
        let flightProgress = eased(t, Beat.flight, curve: easeInOut)
        if flightProgress > 0 {
            var tracer = context
            var outside = Path(CGRect(origin: .zero, size: map.view))
            outside.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            tracer.clip(to: outside, style: FillStyle(eoFill: true))
            drawTracer(in: &tracer, flight: flight, upTo: flightProgress, width: radius * 0.26)
        }

        let lock = eased(t, Beat.lock, curve: easeOutBack)
        if lock > 0 {
            let flash = 1 - eased(t, 0.5...0.8, curve: easeOut)
            drawBrackets(in: &context, center: center, radius: radius, scale: 1.9 - 0.9 * lock,
                         opacity: min(1, lock), flash: t > Beat.lock.upperBound ? flash : 0)
        }

        let land = eased(t, Beat.landing, curve: easeOut)
        if land > 0, land < 1 {
            let end = flight.p3
            let w = radius * (0.6 + 2.2 * land)
            let ring = Path(ellipseIn: CGRect(x: end.x - w, y: end.y - w * 0.22, width: w * 2, height: w * 0.44))
            context.stroke(ring, with: .color(Theme.Palette.tracerCore.opacity(0.9 * (1 - land))), lineWidth: 2.5)
            var glow = context
            glow.addFilter(.blur(radius: 10))
            glow.fill(Path(ellipseIn: CGRect(x: end.x - 18, y: end.y - 18, width: 36, height: 36)),
                      with: .color(Theme.Palette.tracerCore.opacity(1 - land)))
        }
    }

    private func drawTracer(in context: inout GraphicsContext, flight: Flight, upTo progress: Double, width: CGFloat) {
        let samples = 90
        let last = Int((Double(samples) * progress).rounded(.down))
        func strokes(_ ctx: inout GraphicsContext, widthScale: CGFloat, from: Color, to: Color) {
            for i in 0..<max(1, last) {
                let t0 = CGFloat(i) / CGFloat(samples)
                let t1 = min(CGFloat(progress), CGFloat(i + 1) / CGFloat(samples))
                let ramp = min(1, t0 / 0.06)
                let w = (width + (width * 0.28 - width) * pow(t0, 0.8)) * (0.35 + 0.65 * ramp) * widthScale
                var segment = Path()
                segment.move(to: flight.point(t0))
                segment.addLine(to: flight.point(t1))
                ctx.stroke(segment, with: .color(from.mix(with: to, by: Double(pow(t0, 0.7)))),
                           style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        }
        var wide = context
        wide.addFilter(.blur(radius: width * 1.4))
        strokes(&wide, widthScale: 3, from: Theme.Palette.plasma.opacity(0.8), to: Theme.Palette.plasma.opacity(0.55))
        var near = context
        near.addFilter(.blur(radius: width * 0.45))
        strokes(&near, widthScale: 1.5, from: Theme.Palette.plasma, to: Theme.Palette.tracerCore.opacity(0.9))
        strokes(&context, widthScale: 1, from: Color(red: 1, green: 0.54, blue: 0.24), to: Theme.Palette.tracerCore)
        strokes(&context, widthScale: 0.4, from: Theme.Palette.tracerCore, to: .white)

        // The ball itself, at the head of the tracer while it flies.
        if progress < 1 {
            let head = flight.point(CGFloat(progress))
            var glow = context
            glow.addFilter(.blur(radius: width * 1.2))
            glow.fill(Path(ellipseIn: CGRect(x: head.x - width * 2, y: head.y - width * 2, width: width * 4, height: width * 4)),
                      with: .color(Theme.Palette.tracerCore))
            context.fill(Path(ellipseIn: CGRect(x: head.x - width * 0.7, y: head.y - width * 0.7,
                                                width: width * 1.4, height: width * 1.4)), with: .color(.white))
        }
    }

    private func drawBrackets(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                              scale: CGFloat, opacity: Double, flash: Double) {
        let half = radius * 1.42 * scale, corner = radius * 0.5 * scale
        var path = Path()
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] as [(CGFloat, CGFloat)] {
            let x = center.x + sx * half, y = center.y + sy * half
            path.move(to: CGPoint(x: x, y: y - sy * corner))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - sx * corner, y: y))
        }
        let style = StrokeStyle(lineWidth: max(2.5, radius * 0.09), lineCap: .round, lineJoin: .round)
        var glow = context
        glow.addFilter(.blur(radius: radius * 0.18 + 10 * flash))
        glow.stroke(path, with: .color(Theme.Palette.ion.opacity(opacity * (0.85 + 0.15 * flash))), style: style)
        context.stroke(path, with: .color(Theme.Palette.ion.opacity(opacity)), style: style)
    }

    // MARK: Easing

    private func eased(_ t: Double, _ range: ClosedRange<Double>, curve: (Double) -> Double) -> Double {
        guard t > range.lowerBound else { return 0 }
        guard t < range.upperBound else { return 1 }
        return curve((t - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    private func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

/// Where a point of the artwork lands on screen when it's drawn aspect-fill
/// and centered (as `UIImageView.scaleAspectFill` does on the launch screen).
struct ArtworkMap {
    var image: CGSize
    var view: CGSize

    var scale: CGFloat { max(view.width / image.width, view.height / image.height) }
    var origin: CGPoint {
        CGPoint(x: (view.width - image.width * scale) / 2, y: (view.height - image.height * scale) / 2)
    }

    /// `fraction` of the artwork's width and height.
    func point(_ fraction: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + fraction.x * image.width * scale, y: origin.y + fraction.y * image.height * scale)
    }

    /// A length given as a fraction of the artwork's width.
    func length(_ fraction: CGFloat) -> CGFloat { fraction * image.width * scale }
}

private struct Flight {
    var p0, c1, c2, p3: CGPoint
    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }
}
