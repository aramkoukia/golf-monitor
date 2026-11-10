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
