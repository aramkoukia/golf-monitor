import AVFoundation
import CoreGraphics
import Foundation

/// Measured launch of a struck ball.
struct BallLaunch: Equatable {
    var speedMps: Double
    var launchAngleDeg: Double
    /// Frame-accurate impact (seconds into the clip).
    var impactTime: Double
    /// Image velocity in pixels per second (y down).
    var velocityPx: CGVector
    /// Address position followed by every tracked post-impact position.
    var points: [TrackPoint]
    /// 0–1: share of in-view frames that agreed with the fitted line.
    var quality: Double
}

enum LaunchError: LocalizedError, Equatable {
    case unreadableClip
    case ballNotTracked
    case implausible(speedMph: Int, launch: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableClip: return "The shot clip couldn't be read."
        case .ballNotTracked:
            return "The ball left the frame too fast to track. Keep ~2 m of open space in front of the ball and use a fast shutter (1/2000) in good light."
        case .implausible(let speed, let launch):
            return "The ball track looked wrong (\(speed) mph at \(launch)°), so no launch numbers were saved. Make sure the camera is square to the target line."
        }
    }
}

/// Measures ball speed and launch angle from the frames right after impact.
///
/// The scene monitor already knows where the ball sat, how big it is and
/// roughly when it left. Here we (1) pin the impact frame — the first frame
/// whose ball patch differs from a pre-downswing reference — then (2) look,
/// in each of the next ~0.1 s of frames, for *new* bright ball-sized blobs
/// (bright now, dark in the reference: static white things are ignored) and
/// (3) fit a straight line from the address point through them (RANSAC, so
/// a shiny club face or a glint can't drag the result). Over 0.1 s gravity
/// bends the path by < 5 cm, so a line is accurate. Pixels → metres comes
/// from the ball's measured diameter (42.67 mm).
enum LaunchMeasurer {
    struct Blob: Equatable {
        var t: Double
        var center: CGPoint
        /// Area in full-resolution pixels.
        var area: Double
    }

    struct Fit: Equatable {
        var velocity: CGVector
        var inliers: [Blob]
    }

    static func measure(videoURL: URL, impactTimeHint: Double, ballCenter: CGPoint, ballDiameterPx: Double,
                        pixelsPerMeter: Double) async throws -> BallLaunch {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LaunchError.unreadableClip }
        let fps = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, impactTimeHint - FrameScanner.referenceLead),
                                                     preferredTimescale: 6000),
                                       end: CMTime(seconds: impactTimeHint + 0.3, preferredTimescale: 6000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LaunchError.unreadableClip }
        reader.add(output)
        guard reader.startReading() else { throw LaunchError.unreadableClip }

        var scanner = FrameScanner(ballCenter: ballCenter, diameter: ballDiameterPx, impactHint: impactTimeHint)
        var frameSize = CGSize.zero
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let done: Bool = PixelBufferLuma.with(buffer) { luma in
                frameSize = CGSize(width: luma.width, height: luma.height)
                return scanner.ingest(luma, t: t)
            } ?? false
            if done { break }
        }
        reader.cancelReading()

        guard let impact = scanner.impactTime,
              let fit = fit(blobs: scanner.blobs, address: ballCenter, impactTime: impact,
                            diameterPx: ballDiameterPx, fps: fps > 0 ? fps : 240) else {
            throw LaunchError.ballNotTracked
        }
        let refinedImpact = fit.inliers.first.flatMap {
            passTime(through: ballCenter, from: $0, velocity: fit.velocity, diameterPx: ballDiameterPx * 3)
        }.map { min(max($0, impact - 3 / max(fps, 1)), impact + 1 / max(fps, 1)) } ?? impact
        let speedPx = hypot(fit.velocity.dx, fit.velocity.dy)
        let speedMps = speedPx / pixelsPerMeter
        let launch = atan2(-Double(fit.velocity.dy), abs(Double(fit.velocity.dx))) * 180 / .pi
        let mph = speedMps * 2.23694
        guard (15...215).contains(mph), (-8...65).contains(launch) else {
            throw LaunchError.implausible(speedMph: Int(mph.rounded()), launch: Int(launch.rounded()))
        }
        let w = max(Double(frameSize.width), 1), h = max(Double(frameSize.height), 1)
        var points = [TrackPoint(t: refinedImpact, x: Double(ballCenter.x) / w, y: Double(ballCenter.y) / h, confidence: 1)]
        points += fit.inliers.map { TrackPoint(t: $0.t, x: Double($0.center.x) / w, y: Double($0.center.y) / h, confidence: 1) }
        let quality = min(1, Double(fit.inliers.count) / Double(max(2, scanner.framesWithBlobs)))
        return BallLaunch(speedMps: speedMps, launchAngleDeg: launch, impactTime: refinedImpact,
                          velocityPx: fit.velocity, points: points, quality: quality)
    }

    /// RANSAC line fit: every pair of moving blobs proposes a velocity; a
    /// proposal must trace back through the address point (where the ball
    /// sat) around the impact time, and the one most other blobs agree with
    /// wins. A least-squares refit over its inliers gives the velocity, and
    /// the moment the line passes the address is the sub-frame impact time.
    static func fit(blobs: [Blob], address: CGPoint, impactTime: Double, diameterPx: Double, fps: Double) -> Fit? {
        let frame = 1 / max(fps, 1)
        let candidates = movingBlobs(blobs, diameterPx: diameterPx).filter { $0.t > impactTime - frame / 2 }
        var best: (inliers: [Blob], residual: Double)?
        for (i, a) in candidates.enumerated() {
            for b in candidates[(i + 1)...] where b.t > a.t + frame / 2 {
                let v = CGVector(dx: (b.center.x - a.center.x) / (b.t - a.t), dy: (b.center.y - a.center.y) / (b.t - a.t))
                let speed = Double(hypot(v.dx, v.dy))
                // A struck ball moves at least ~0.8 diameters per frame at 240 fps
                // (≈ 20 mph); anything slower is the golfer or the club.
                guard speed / 240 >= 0.8 * diameterPx else { continue }
                guard let origin = passTime(through: address, from: a, velocity: v, diameterPx: diameterPx),
                      origin >= impactTime - 3 * frame, origin <= a.t else { continue }
                let tolerance = max(diameterPx, 0.25 * speed * frame)
                var byFrame: [Double: (Blob, Double)] = [:]
                for c in candidates {
                    let e = Double(hypot(a.center.x + v.dx * (c.t - a.t) - c.center.x,
                                         a.center.y + v.dy * (c.t - a.t) - c.center.y))
                    guard e <= tolerance else { continue }
                    if let existing = byFrame[c.t], existing.1 <= e { continue }
                    byFrame[c.t] = (c, e)
                }
                let inliers = byFrame.values.map(\.0).sorted { $0.t < $1.t }
                let residual = byFrame.values.map(\.1).reduce(0, +) / Double(max(1, byFrame.count))
                if let current = best {
                    if inliers.count < current.inliers.count { continue }
                    if inliers.count == current.inliers.count, residual >= current.residual { continue }
                }
                best = (inliers, residual)
            }
        }
        guard let best, best.inliers.count >= 2,
              let vx = slope(best.inliers.map(\.t), best.inliers.map { Double($0.center.x) }),
              let vy = slope(best.inliers.map(\.t), best.inliers.map { Double($0.center.y) }) else { return nil }
        return Fit(velocity: CGVector(dx: vx, dy: vy), inliers: best.inliers)
    }

    /// When a ball at `blob` moving with `velocity` was closest to `address`,
    /// if it passed within ~1.5 diameters of it.
    static func passTime(through address: CGPoint, from blob: Blob, velocity v: CGVector, diameterPx: Double) -> Double? {
        let speed2 = Double(v.dx * v.dx + v.dy * v.dy)
        guard speed2 > 0 else { return nil }
        let dx = Double(address.x - blob.center.x), dy = Double(address.y - blob.center.y)
        let dt = (dx * Double(v.dx) + dy * Double(v.dy)) / speed2
        let px = Double(blob.center.x) + Double(v.dx) * dt, py = Double(blob.center.y) + Double(v.dy) * dt
        guard hypot(px - Double(address.x), py - Double(address.y)) <= 1.5 * diameterPx else { return nil }
        return blob.t + dt
    }

    /// Drops blobs that sit (nearly) still between consecutive frames — bits
    /// of the golfer, glints, camera shake — keeping fast movers like the ball.
    static func movingBlobs(_ blobs: [Blob], diameterPx: Double) -> [Blob] {
        let times = Array(Set(blobs.map(\.t))).sorted()
        let byTime = Dictionary(grouping: blobs, by: \.t)
        var kept: [Blob] = []
        for (i, t) in times.enumerated() {
            let neighbours = [i > 0 ? times[i - 1] : nil, i + 1 < times.count ? times[i + 1] : nil]
                .compactMap { $0 }.flatMap { byTime[$0] ?? [] }
            for b in byTime[t] ?? [] where !neighbours.contains(where: {
                hypot($0.center.x - b.center.x, $0.center.y - b.center.y) < CGFloat(0.6 * diameterPx)
            }) {
                kept.append(b)
            }
        }
        return kept
    }

    static func slope(_ t: [Double], _ v: [Double]) -> Double? {
        let n = Double(t.count)
        guard n >= 2 else { return nil }
        let mt = t.reduce(0, +) / n, mv = v.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in t.indices {
            num += (t[i] - mt) * (v[i] - mv)
            den += (t[i] - mt) * (t[i] - mt)
        }
        return den > 1e-12 ? num / den : nil
    }
}

/// Streaming per-frame work for `LaunchMeasurer` (kept separate so it can be
/// fed synthetic frames in tests).
struct FrameScanner {
    let ballCenter: CGPoint
    let diameter: Double
    let impactHint: Double
    /// Seconds after impact to keep looking for the ball.
    var trackWindow = 0.1
    /// The reference frame is taken this long before the impact hint: the
    /// ball is still there, the club is ~2 m away, and the golfer has barely
    /// moved relative to the frames after impact.
    static let referenceLead = 0.09

    private(set) var impactTime: Double?
    private(set) var blobs: [LaunchMeasurer.Blob] = []
    private(set) var framesWithBlobs = 0
    private var reference: ArrayLuma?
    private var previous: ArrayLuma?
    private var referenceDisk: [UInt8] = []
    private var brightThreshold = 200
    private var emptyFramesAfterBlobs = 0

    init(ballCenter: CGPoint, diameter: Double, impactHint: Double) {
        self.ballCenter = ballCenter
        self.diameter = diameter
        self.impactHint = impactHint
    }

    /// Returns true when no more frames are needed.
    mutating func ingest(_ luma: LumaImage, t: Double) -> Bool {
        let radius = diameter * 0.35
        guard let reference else {
            // Reference from the first frame (~0.3 s before impact): the ball
            // is there and the club is still far away at the top / early downswing.
            let copy = ArrayLuma(copying: luma)
            reference = copy
            previous = copy
            referenceDisk = luma.disk(center: ballCenter, radius: radius)
            brightThreshold = Self.threshold(around: ballCenter, diameter: diameter, in: luma)
            return false
        }
        defer { previous = ArrayLuma(copying: luma) }

        if impactTime == nil {
            let diff = meanAbsoluteDifference(referenceDisk, luma.disk(center: ballCenter, radius: radius))
            if diff > 0.14 {
                impactTime = t
            } else if t > impactHint + 0.15 {
                return true
            }
            return false
        }
        guard let impact = impactTime, t <= impact + trackWindow else { return true }

        let found = Self.newBrightBlobs(in: luma, reference: reference, previous: previous ?? reference,
                                        threshold: brightThreshold, ballCenter: ballCenter, diameter: diameter, t: t)
        if found.isEmpty {
            if framesWithBlobs > 0 { emptyFramesAfterBlobs += 1 }
            return emptyFramesAfterBlobs >= 6
        }
        emptyFramesAfterBlobs = 0
        framesWithBlobs += 1
        blobs += found
        return false
    }

    /// Halfway between the ball's brightness and its surroundings, a bit
    /// lower to allow for motion blur.
    static func threshold(around center: CGPoint, diameter: Double, in luma: LumaImage) -> Int {
        let inner = luma.disk(center: center, radius: diameter * 0.35).map(Int.init).sorted()
        var ring: [Int] = []
        for k in 0..<24 {
            let a = Double(k) / 24 * 2 * .pi
            let x = Int(Double(center.x) + cos(a) * diameter * 1.2), y = Int(Double(center.y) + sin(a) * diameter * 1.2)
            if x >= 0, y >= 0, x < luma.width, y < luma.height { ring.append(Int(luma.luma(x: x, y: y))) }
        }
        guard !inner.isEmpty, !ring.isEmpty else { return 200 }
        ring.sort()
        let peak = inner[inner.count * 3 / 4], background = ring[ring.count / 2]
        return max(background + 25, background + Int(Double(peak - background) * 0.45))
    }

    /// Connected regions (on a 2-px grid) that are bright now but were dark
    /// both before the downswing and in the previous frame, sized and shaped
    /// like a (possibly motion-blurred) ball.
    static func newBrightBlobs(in luma: LumaImage, reference: ArrayLuma, previous: ArrayLuma, threshold: Int,
                               ballCenter: CGPoint, diameter: Double, t: Double) -> [LaunchMeasurer.Blob] {
        let step = diameter >= 14 ? 2 : 1
        let gw = luma.width / step, gh = min(luma.height, Int(Double(ballCenter.y) + diameter * 2)) / step
        guard gw > 0, gh > 0 else { return [] }
        var mask = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            let y = gy * step
            for gx in 0..<gw {
                let x = gx * step
                if Int(luma.luma(x: x, y: y)) >= threshold, Int(reference.luma(x: x, y: y)) < threshold - 15,
                   Int(previous.luma(x: x, y: y)) < threshold - 15 {
                    mask[gy * gw + gx] = true
                }
            }
        }
        let ballArea = Double.pi * diameter * diameter / 4
        let cell = Double(step * step)
        var blobs: [LaunchMeasurer.Blob] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] {
            mask[start] = false
            stack.append(start)
            var count = 0, sx = 0, sy = 0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            while let i = stack.popLast() {
                let x = i % gw, y = i / gw
                count += 1; sx += x; sy += y
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                    let j = ny * gw + nx
                    if mask[j] { mask[j] = false; stack.append(j) }
                }
            }
            let area = Double(count) * cell
            let boxW = Double((maxX - minX + 1) * step), boxH = Double((maxY - minY + 1) * step)
            let compactness = area / max(boxW * boxH, 1)
            guard area >= ballArea * 0.2, area <= ballArea * 6, max(boxW, boxH) <= diameter * 5,
                  compactness >= 0.3 else { continue }
            blobs.append(LaunchMeasurer.Blob(t: t, center: CGPoint(x: Double(sx) / Double(count) * Double(step),
                                                                   y: Double(sy) / Double(count) * Double(step)),
                                             area: area))
        }
        return blobs
    }
}

extension ArrayLuma {
    init(copying luma: LumaImage) {
        self.init(width: luma.width, height: luma.height)
        for y in 0..<luma.height {
            for x in 0..<luma.width { pixels[y * luma.width + x] = luma.luma(x: x, y: y) }
        }
    }
}
