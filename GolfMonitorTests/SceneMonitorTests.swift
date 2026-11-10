import CoreVideo
import XCTest
@testable import GolfMonitor

/// Scene monitor on synthetic frames: locking, gone vs hidden, motion.
final class SceneMonitorTests: XCTestCase {
    /// Reports its candidates only where the frame actually shows a bright
    /// ball (like the real detector, it can't see a hidden ball).
    final class FakeLocator: BallLocating {
        var candidates: [BallCandidate]
        private(set) var calls = 0
        init(_ candidates: [BallCandidate]) { self.candidates = candidates }
        func candidates(in pixelBuffer: CVPixelBuffer) -> [BallCandidate] {
            calls += 1
            return PixelBufferLuma.with(pixelBuffer) { luma in
                candidates.filter { luma.luma(x: Int($0.center.x), y: Int($0.center.y)) > 180 }
            } ?? []
        }
    }

    private let ballCenter = CGPoint(x: 160, y: 200)
    private let width = 320, height = 320

    private func makeMonitor(_ locator: BallLocating) -> SceneMonitor {
        var config = SceneMonitor.Config()
        config.synchronousDetection = true
        config.locateInterval = 0.2
        return SceneMonitor(config: config, locator: locator)
    }

    private func frame(ball: Bool, block: CGRect? = nil) -> CVPixelBuffer {
        var luma = ArrayLuma(width: width, height: height, fill: 70)
        if ball { luma.fillCircle(center: ballCenter, radius: 10, value: 235) }
        if let block { luma.fillRect(block, value: 200) }
        return Self.pixelBuffer(luma)
    }

    /// 420f buffer whose Y plane is `luma`.
    static func pixelBuffer(_ luma: ArrayLuma) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, luma.width, luma.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<luma.height {
            for x in 0..<luma.width { base[y * stride + x] = luma.pixels[y * luma.width + x] }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func feed(_ monitor: SceneMonitor, from start: Double, to end: Double, _ make: (Double) -> CVPixelBuffer) {
        var t = start
        while t < end {
            monitor.ingest(make(t), time: t)
            t += 1.0 / 30
        }
    }

    private var candidate: BallCandidate { BallCandidate(center: ballCenter, diameterPx: 20, confidence: 0.8) }

    func testLocksAStationaryBallAfterRepeatedSightings() {
        let locator = FakeLocator([candidate])
        let monitor = makeMonitor(locator)
        feed(monitor, from: 0, to: 0.3) { _ in frame(ball: true) }
        XCTAssertFalse(monitor.currentSnapshot.isBallLocked, "one or two sightings are not enough")
        feed(monitor, from: 0.3, to: 1.2) { _ in frame(ball: true) }
        let snapshot = monitor.currentSnapshot
        XCTAssertTrue(snapshot.isBallLocked)
        XCTAssertEqual(snapshot.locks.first?.center.x ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.frameAspect, 1, accuracy: 0.01)
    }

    func testStruckBallIsGoneAndAppearsInTheTimeline() {
        let locator = FakeLocator([candidate])
        let m = makeMonitor(locator)
        feed(m, from: 0, to: 2) { _ in frame(ball: true) }
        // The ball is hit at t = 2 and the locator no longer sees it.
        locator.candidates = []
        feed(m, from: 2, to: 4) { _ in frame(ball: false) }
        let timeline = m.timeline(from: 0, to: 4)
        let track = try! XCTUnwrap(timeline.balls.first)
        XCTAssertEqual(track.goneSince ?? 0, 2, accuracy: 0.05)
        XCTAssertFalse(m.currentSnapshot.isBallLocked)
        XCTAssertEqual(ShotFinder().departureTime(of: track, timelineEnd: 4, isFinal: true) ?? 0, 2, accuracy: 0.05)
    }

    func testBallHiddenBrieflyIsStillThere() {
        let locator = FakeLocator([candidate])
        let monitor = makeMonitor(locator)
        feed(monitor, from: 0, to: 1.5) { _ in frame(ball: true) }
        // Golfer walks in front of it for 1.3 s.
        feed(monitor, from: 1.5, to: 2.8) { _ in frame(ball: false) }
        feed(monitor, from: 2.8, to: 4) { _ in frame(ball: true) }
        let track = try! XCTUnwrap(monitor.timeline(from: 0, to: 4).balls.first)
        XCTAssertNil(track.goneSince, "it came back, so it was only hidden")
        XCTAssertNil(ShotFinder().departureTime(of: track, timelineEnd: 4, isFinal: true))
        XCTAssertEqual(monitor.timeline(from: 0, to: 4).balls.count, 1, "no duplicate lock for the same ball")
    }

    func testMotionEnergyRisesWhenSomethingMoves() {
        let monitor = makeMonitor(FakeLocator([]))
        feed(monitor, from: 0, to: 1) { _ in frame(ball: false) }
        feed(monitor, from: 1, to: 2) { t in
            frame(ball: false, block: CGRect(x: (t - 1) * 250, y: 40, width: 60, height: 120))
        }
        let motion = monitor.timeline(from: 0, to: 2).motion
        let still = motion.filter { $0.t > 0.1 && $0.t < 1 }.map(\.energy).max() ?? 1
        let moving = motion.filter { $0.t > 1.1 }.map(\.energy).max() ?? 0
        XCTAssertLessThan(still, 0.001)
        XCTAssertGreaterThan(moving, 0.01)
    }

    func testThrottlesToThirtyFramesASecond() {
        let monitor = makeMonitor(FakeLocator([]))
        var t = 0.0
        while t < 1 {
            monitor.ingest(frame(ball: false), time: t)
            t += 1.0 / 240
        }
        XCTAssertEqual(Double(monitor.timeline(from: 0, to: 1).motion.count), 30, accuracy: 2)
    }

    func testDetectorRunsOnlyWhileLookingForBalls() {
        let locator = FakeLocator([candidate])
        var config = SceneMonitor.Config()
        config.synchronousDetection = true
        config.locateInterval = 0.2
        config.maxLocks = 1
        let monitor = SceneMonitor(config: config, locator: locator)
        feed(monitor, from: 0, to: 3) { _ in frame(ball: true) }
        XCTAssertLessThanOrEqual(locator.calls, 5, "stops locating once the ball is locked (max 1)")
    }
}
