import XCTest
@testable import GolfMonitor

/// Shot finding on synthetic timelines: practice swings vs the real strike,
/// hidden balls, camera bumps and the swing-only fallback.
final class ShotFinderTests: XCTestCase {
    private let finder = ShotFinder()

    // MARK: Builders

    /// 30 Hz motion: still (noise) with swing-shaped bursts.
    private func motion(duration: Double, swings: [ClosedRange<Double>], peak: Float = 0.04) -> [MotionSample] {
        stride(from: 0.0, through: duration, by: 1.0 / 30).map { t in
            var e: Float = 0.002 + Float((t * 7).truncatingRemainder(dividingBy: 1)) * 0.001
            for s in swings where s.contains(t) {
                let phase = (t - s.lowerBound) / (s.upperBound - s.lowerBound)
                e += peak * Float(sin(phase * .pi))
            }
            return MotionSample(t: t, energy: e)
        }
    }

    /// Presence samples: 0.01 while there, `gone` level inside each absent range.
    func ball(at center: CGPoint = CGPoint(x: 400, y: 900), duration: Double,
                      absent: [ClosedRange<Double>], gone: Float = 0.35, nudge: ClosedRange<Double>? = nil) -> BallTrack {
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 30).map { t -> PresenceSample in
            if absent.contains(where: { $0.contains(t) }) { return PresenceSample(t: t, difference: gone) }
            if let nudge, nudge.contains(t) { return PresenceSample(t: t, difference: 0.16) }
            return PresenceSample(t: t, difference: 0.01)
        }
        return BallTrack(center: center, diameterPx: 20, frameWidth: 1080, frameHeight: 1920,
                         confidence: 0.5, lockedAt: 0, presence: samples)
    }

    // MARK: Tests

    func testPracticeSwingsThenStrikeFindsOneShotAtImpact() {
        let timeline = SceneTimeline(duration: 14,
                                     motion: motion(duration: 14, swings: [2...3.6, 5...6.6, 9...10.8]),
                                     balls: [ball(duration: 14, absent: [10.1...14])])
        let result = finder.analyze(timeline)
        XCTAssertEqual(result.swings.count, 3)
        XCTAssertEqual(result.practiceSwingCount, 2)
        XCTAssertEqual(result.struckCount, 1)
        let shot = try! XCTUnwrap(result.shots.first)
        XCTAssertEqual(shot.kind, .struck)
        XCTAssertEqual(shot.impactTime ?? 0, 10.1, accuracy: 0.04)
        XCTAssertEqual(shot.clipStart, 10.1 - finder.config.preRoll, accuracy: 0.04)
        XCTAssertEqual(shot.clipEnd, 10.1 + finder.config.postRoll, accuracy: 0.04)
        XCTAssertNotNil(shot.ball)
    }

    func testBallHiddenDuringSwingThatComesBackIsNotAShot() {
        let timeline = SceneTimeline(duration: 8, motion: motion(duration: 8, swings: [2...3.8]),
                                     balls: [ball(duration: 8, absent: [2.5...3.6])])
        let result = finder.analyze(timeline)
        XCTAssertEqual(result.struckCount, 0)
        XCTAssertEqual(result.shots.first?.kind, .swingOnly, "falls back to the swing")
    }

    func testStrikeRightBeforeStopIsFound() {
        // Recording stopped 0.4 s after impact.
        let timeline = SceneTimeline(duration: 6, motion: motion(duration: 6, swings: [4.2...6]),
                                     balls: [ball(duration: 6, absent: [5.6...6])])
        XCTAssertEqual(finder.analyze(timeline).struckCount, 1)
        XCTAssertEqual(finder.analyze(timeline, isFinal: false).struckCount, 0,
                       "while still recording, a ball must be gone longer before it counts")
    }

    func testCameraBumpMovingEveryBallAtOnceIsIgnored() {
        let balls = [CGPoint(x: 300, y: 900), CGPoint(x: 700, y: 950), CGPoint(x: 500, y: 1200)].map {
            ball(at: $0, duration: 8, absent: [3.0...8])
        }
        let timeline = SceneTimeline(duration: 8, motion: motion(duration: 8, swings: [2.6...4]), balls: balls)
        XCTAssertEqual(finder.analyze(timeline).struckCount, 0)
    }

    func testEarliestDisappearanceInASwingIsTheStrike() {
        let teed = ball(at: CGPoint(x: 400, y: 900), duration: 8, absent: [4.0...8])
        let hiddenByFollowThrough = ball(at: CGPoint(x: 800, y: 1300), duration: 8, absent: [4.5...8])
        let timeline = SceneTimeline(duration: 8, motion: motion(duration: 8, swings: [3...5]),
                                     balls: [hiddenByFollowThrough, teed])
        let shots = finder.analyze(timeline).shots
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(shots.first?.ball?.center, teed.center)
    }

    func testImpactIsPinnedPastTheTakeawayNudge() {
        // Club head leaving the ball at takeaway nudges the patch to 0.16
        // (just over threshold) until impact at 4.0, then the ball is gone (0.35).
        let b = ball(duration: 8, absent: [4.0...8], nudge: 3.0...3.99)
        XCTAssertEqual(finder.departureTime(of: b, timelineEnd: 8, isFinal: true) ?? 0, 4.0, accuracy: 0.04)
    }

    func testNoBallFallsBackToLastSwingAsSwingOnly() {
        let timeline = SceneTimeline(duration: 10, motion: motion(duration: 10, swings: [2...3.5, 6...7.6]))
        let result = finder.analyze(timeline)
        XCTAssertEqual(result.shots.count, 1)
        let shot = result.shots[0]
        XCTAssertEqual(shot.kind, .swingOnly)
        XCTAssertNil(shot.impactTime)
        XCTAssertTrue(shot.clipStart < 6 && shot.clipEnd > 7.6, "clip covers the last swing")
        XCTAssertFalse(finder.analyze(timeline, isFinal: false).shots.contains { $0.kind == .swingOnly })
    }

    func testStillRecordingHasNoSwingsOrShots() {
        let timeline = SceneTimeline(duration: 10, motion: motion(duration: 10, swings: []),
                                     balls: [ball(duration: 10, absent: [])])
        let result = finder.analyze(timeline)
        XCTAssertTrue(result.swings.isEmpty)
        XCTAssertTrue(result.shots.isEmpty)
    }

    func testTwoStrikesInOneRecording() {
        let first = ball(at: CGPoint(x: 400, y: 900), duration: 16, absent: [4.0...16])
        var second = ball(at: CGPoint(x: 400, y: 900), duration: 16, absent: [11.0...16])
        second.lockedAt = 7
        second.presence.removeAll { $0.t < 7 }
        let timeline = SceneTimeline(duration: 16, motion: motion(duration: 16, swings: [3...5, 10...12]),
                                     balls: [first, second])
        let result = finder.analyze(timeline)
        XCTAssertEqual(result.struckCount, 2)
        XCTAssertEqual(result.shots.map { ($0.impactTime ?? 0).rounded() }, [4, 11])
    }

    func testTimelineSliceRebasesTimes() {
        let motion = (0..<100).map { MotionSample(t: 100 + Double($0) * 0.1, energy: 0.01) }
        var track = BallTrack(center: .zero, diameterPx: 20, frameWidth: 10, frameHeight: 10, confidence: 1, lockedAt: 95)
        track.presence = (0..<100).map { PresenceSample(t: 100 + Double($0) * 0.1, difference: 0) }
        let slice = SceneTimeline.slice(motion: motion, balls: [track], from: 102, to: 105)
        XCTAssertEqual(slice.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(slice.motion.first?.t ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(slice.motion.last?.t ?? -1, 3, accuracy: 0.11)
        XCTAssertEqual(slice.balls.first?.lockedAt, 0)
        XCTAssertEqual(slice.balls.first?.presence.count, slice.motion.count)
    }
}

// MARK: - Rushed routines

/// Recordings that are mostly movement: record pressed on the phone, a walk
/// to the ball, a swing with no pause, a walk back to press stop. Energies
/// follow the 240 fps fixtures (a swing is ~0.02–0.04); walking close past
/// the camera is assumed to be as strong or stronger.
extension ShotFinderTests {
    private enum Part {
        case still(Double)
        case moving(Double, Float)
        /// Swing-shaped burst (sine bump), `peak` above the still level.
        case swing(Double, peak: Float)
    }

    /// 30 Hz motion, played out part by part, with a little texture so the
    /// smoothing has real dips and peaks to work on.
    private func routine(_ parts: [Part]) -> (motion: [MotionSample], duration: Double, swingPeaks: [Double]) {
        var samples: [MotionSample] = []
        var peaks: [Double] = []
        var t = 0.0
        let dt = 1.0 / 30
        func emit(_ e: Float) {
            let texture = 1 + 0.15 * Float(sin(t * 23))
            samples.append(MotionSample(t: t, energy: 0.002 + e * texture))
            t += dt
        }
        for part in parts {
            switch part {
            case .still(let d):
                for _ in 0..<Int(d * 30) { emit(0) }
            case .moving(let d, let e):
                for _ in 0..<Int(d * 30) { emit(e) }
            case .swing(let d, let peak):
                peaks.append(t + d / 2)
                let n = Int(d * 30)
                for i in 0..<n { emit(peak * Float(sin(Double(i) / Double(n - 1) * .pi))) }
            }
        }
        return (samples, t, peaks)
    }

    private static let walk: Float = 0.05
    private static let setUp: Float = 0.01

    func testRushedRoutineOnThePhoneStillFindsTheSwing() {
        // Nothing still in it at all: the old bar (6 × the whole recording's
        // spread) rose above the swing and "No swing was found".
        let r = routine([.moving(1.5, Self.walk), .moving(0.8, Self.setUp), .swing(1.6, peak: 0.035),
                         .moving(0.4, Self.setUp), .moving(1.5, Self.walk)])
        let result = finder.analyze(SceneTimeline(duration: r.duration, motion: r.motion), stoppedAtPhone: true)
        XCTAssertEqual(result.swings.count, 1, "\(result.swings)")
        let shot = try! XCTUnwrap(result.shots.first)
        XCTAssertEqual(shot.kind, .swingOnly)
        XCTAssertEqual(shot.swing?.peakTime ?? 0, r.swingPeaks[0], accuracy: 0.2, "the swing, not a walk")
        XCTAssertEqual(result.practiceSwingCount, 1, "walking to and from the phone isn't a swing")
    }

    func testRushedRoutineWithALockedBallFindsTheStrike() {
        let r = routine([.moving(1.5, Self.walk), .moving(0.8, Self.setUp), .swing(1.6, peak: 0.035),
                         .moving(0.4, Self.setUp), .moving(1.5, Self.walk)])
        let impact = r.swingPeaks[0]
        let timeline = SceneTimeline(duration: r.duration, motion: r.motion,
                                     balls: [ball(duration: r.duration, absent: [impact...r.duration])])
        let result = finder.analyze(timeline, stoppedAtPhone: true)
        XCTAssertEqual(result.struckCount, 1)
        XCTAssertEqual(result.shots.first?.impactTime ?? 0, impact, accuracy: 0.04)
        XCTAssertEqual(result.practiceSwingCount, 0)
    }

    func testMostlyMovingRecordingWithShortPausesFindsTheSwing() {
        // Less than half of it still: the old bar jumped ~10× here.
        let r = routine([.moving(1.5, Self.walk), .moving(0.8, Self.setUp), .still(1.0), .swing(1.6, peak: 0.03),
                         .still(1.0), .moving(1.5, Self.walk)])
        let result = finder.analyze(SceneTimeline(duration: r.duration, motion: r.motion), stoppedAtPhone: true)
        XCTAssertEqual(result.swings.count, 1)
        XCTAssertEqual(result.shots.first?.swing?.peakTime ?? 0, r.swingPeaks[0], accuracy: 0.2)
    }

    func testPracticeSwingAndShotBetweenWalksAreBothFound() {
        let r = routine([.moving(1.5, Self.walk), .still(1.0), .swing(1.6, peak: 0.03), .still(1.2),
                         .swing(1.6, peak: 0.035), .still(1.0), .moving(1.2, Self.walk)])
        let result = finder.analyze(SceneTimeline(duration: r.duration, motion: r.motion), stoppedAtPhone: true)
        XCTAssertEqual(result.swings.count, 2, "\(result.swings)")
        XCTAssertEqual(result.shots.first?.swing?.peakTime ?? 0, r.swingPeaks[1], accuracy: 0.2,
                       "swing-only falls back to the last real swing, not the walk to the phone")
    }

    func testWalkingWithoutASwingIsNotASwing() {
        let r = routine([.moving(1.5, Self.walk), .still(3), .moving(1.5, Self.walk)])
        let result = finder.analyze(SceneTimeline(duration: r.duration, motion: r.motion), stoppedAtPhone: true)
        XCTAssertTrue(result.swings.isEmpty)
        XCTAssertTrue(result.shots.isEmpty, "nothing to analyze → \"No swing was found\"")
    }

    func testSwingRightBeforeAWatchStopIsKept() {
        // Stopped from the watch while relaxing out of the finish: the end
        // of the recording is the golfer, not someone at the phone.
        let r = routine([.still(2), .swing(1.6, peak: 0.03), .moving(0.5, 0.012)])
        let timeline = SceneTimeline(duration: r.duration, motion: r.motion)
        XCTAssertEqual(finder.analyze(timeline, stoppedAtPhone: false).shots.first?.kind, .swingOnly)
    }

    func testWalkAwayAfterPressingRecordIsNotCountedLive() {
        let r = routine([.moving(1.5, Self.walk), .still(2), .swing(1.6, peak: 0.03), .still(0.5)])
        let live = finder.analyze(SceneTimeline(duration: r.duration, motion: r.motion), isFinal: false)
        XCTAssertEqual(live.swings.count, 1)
    }

    func testStrikeInMotionTooLongToBeASwingIsStillAShot() {
        // 6 s of unbroken movement can't be split into a swing, but the ball
        // left in the middle of it: that's the shot.
        let r = routine([.still(1), .moving(6, 0.03), .still(1)])
        let timeline = SceneTimeline(duration: r.duration, motion: r.motion,
                                     balls: [ball(duration: r.duration, absent: [4.0...r.duration])])
        let result = finder.analyze(timeline)
        XCTAssertEqual(result.struckCount, 1)
        XCTAssertEqual(result.shots.first?.impactTime ?? 0, 4.0, accuracy: 0.04)
        XCTAssertEqual(result.shots.first?.clipStart ?? 0, 4.0 - finder.config.preRoll, accuracy: 0.04)
    }

    func testBallTakenAwayWithoutMotionIsNotAShot() {
        // Exposure jump / lighting change: patch changes, nothing moved.
        let r = routine([.still(8)])
        let timeline = SceneTimeline(duration: r.duration, motion: r.motion,
                                     balls: [ball(duration: r.duration, absent: [4.0...r.duration])])
        XCTAssertEqual(finder.analyze(timeline).struckCount, 0)
    }
}

extension ShotFinderTests {
    func testFirstStrikeInASingleSwingClip() {
        let timeline = SceneTimeline(duration: 2, motion: [], balls: [
            ball(at: CGPoint(x: 400, y: 900), duration: 2, absent: [1.25...2]),
            ball(at: CGPoint(x: 700, y: 1300), duration: 2, absent: [1.6...2]),
        ])
        let strike = ShotFinder().firstStrike(in: timeline)
        XCTAssertEqual(strike?.time ?? 0, 1.25, accuracy: 0.04)
        XCTAssertEqual(strike?.ball.center, CGPoint(x: 400, y: 900))
    }
}
