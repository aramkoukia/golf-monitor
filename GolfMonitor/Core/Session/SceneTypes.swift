import CoreGraphics
import Foundation

// Value types describing what the camera saw during a recording. Produced
// live by `SceneMonitor` (or offline by `SceneScanner`) and consumed by
// `ShotFinder`. Times are seconds; inside a `SceneTimeline` they are relative
// to the start of the recording.

/// Whole-frame motion energy at one instant (0 = still, ~0.1 = a fast swing).
struct MotionSample: Codable, Equatable, Sendable {
    var t: Double
    var energy: Float
}

/// How different the locked ball patch looks from its reference at one
/// instant (0 = identical, 1 = completely different).
struct PresenceSample: Codable, Equatable, Sendable {
    var t: Double
    var difference: Float
}

/// A stationary ball the monitor locked onto, plus the history of whether it
/// was still there. A ball that disappears during a swing was hit.
struct BallTrack: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Ball center in upright frame pixels (top-left origin).
    var center: CGPoint
    /// Measured ball diameter in pixels → calibration (42.67 mm ball).
    var diameterPx: Double
    var frameWidth: Int
    var frameHeight: Int
    var confidence: Float
    var lockedAt: Double
    /// Since when the ball has been missing for good (nil while it's there,
    /// or after it turned out to be only hidden).
    var goneSince: Double? = nil
    var presence: [PresenceSample] = []

    var normalizedCenter: CGPoint {
        CGPoint(x: center.x / CGFloat(max(frameWidth, 1)), y: center.y / CGFloat(max(frameHeight, 1)))
    }
}

/// Everything observed during one recording.
struct SceneTimeline: Codable, Equatable, Sendable {
    var duration: Double
    var motion: [MotionSample] = []
    var balls: [BallTrack] = []

    static let empty = SceneTimeline(duration: 0)

    /// Samples between absolute times `start` and `end`, re-based so that
    /// `start` becomes 0. Balls are kept if they were watched in the window.
    static func slice(motion: [MotionSample], balls: [BallTrack], from start: Double, to end: Double) -> SceneTimeline {
        let window = start...max(start, end)
        let m = motion.filter { window.contains($0.t) }.map { MotionSample(t: $0.t - start, energy: $0.energy) }
        let b = balls.compactMap { ball -> BallTrack? in
            if let last = ball.presence.last?.t, last < start { return nil }
            if ball.lockedAt > end { return nil }
            var copy = ball
            copy.lockedAt = max(0, ball.lockedAt - start)
            copy.goneSince = ball.goneSince.map { $0 - start }
            copy.presence = ball.presence.filter { window.contains($0.t) }
                .map { PresenceSample(t: $0.t - start, difference: $0.difference) }
            return copy
        }
        return SceneTimeline(duration: max(0, end - start), motion: m, balls: b)
    }
}

/// A ball candidate from the detector, before it is locked.
struct BallCandidate: Equatable, Sendable {
    var center: CGPoint
    var diameterPx: Double
    var confidence: Float
}

/// Live overlay data for the viewfinder (normalized coordinates).
struct SceneSnapshot: Equatable, Sendable {
    struct Lock: Equatable, Sendable, Identifiable {
        var id: UUID
        var center: CGPoint
        var diameter: CGFloat
        var isPresent: Bool
    }

    var locks: [Lock] = []
    /// Normalized frame aspect (width / height) the coordinates refer to.
    var frameAspect: CGFloat = 9.0 / 16.0
    var motionLevel: Float = 0
    /// Mean frame brightness, 0...1 (nil before the first frame).
    var brightness: Float? = nil

    var isBallLocked: Bool { locks.contains { $0.isPresent } }
    static let empty = SceneSnapshot()
}
