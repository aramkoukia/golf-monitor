import XCTest
@testable import GolfMonitor

/// Overlay geometry, preview encoding, settings and ball measurement.
final class SupportTests: XCTestCase {
    func testAspectFillMapsCenterAndCropsTheLongSide() {
        // 9:16 frame in a 390×844 view: fills width-limited by height.
        let map = AspectFillMapping(viewSize: CGSize(width: 390, height: 844), frameAspect: 9.0 / 16.0)
        XCTAssertEqual(map.point(CGPoint(x: 0.5, y: 0.5)).x, 195, accuracy: 0.01)
        XCTAssertEqual(map.point(CGPoint(x: 0.5, y: 0.5)).y, 422, accuracy: 0.01)
        XCTAssertEqual(map.point(CGPoint(x: 0, y: 0)).y, 0, accuracy: 0.01)
        XCTAssertLessThan(map.point(CGPoint(x: 0, y: 0)).x, 0, "sides are cropped")
    }

    func testAspectFitLetterboxes() {
        let map = AspectFitMapping(viewSize: CGSize(width: 400, height: 400), frameAspect: 0.5)
        XCTAssertEqual(map.displayedRect, CGRect(x: 100, y: 0, width: 200, height: 400))
        XCTAssertEqual(map.point(CGPoint(x: 1, y: 1)), CGPoint(x: 300, y: 400))
    }

    func testPreviewFramesAreSmallJPEGs() throws {
        var luma = ArrayLuma(width: 1080, height: 1920, fill: 90)
        luma.fillCircle(center: CGPoint(x: 540, y: 1400), radius: 30, value: 240)
        let streamer = WatchPreviewStreamer()
        let data = try XCTUnwrap(streamer.encode(SceneMonitorTests.pixelBuffer(luma)))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG")
        XCTAssertLessThan(data.count, 25_000)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height) * image.scale, streamer.maxDimension + 1)
    }

    func testPreviewStreamsOnlyWithALeaseAndOneFrameInFlight() {
        let streamer = WatchPreviewStreamer()
        streamer.interval = 0
        var active = false
        var sent = 0
        let done = expectation(description: "sent")
        done.assertForOverFulfill = false
        streamer.isActive = { active }
        streamer.send = { _ in
            sent += 1
            done.fulfill()
        }
        let frame = SceneMonitorTests.pixelBuffer(ArrayLuma(width: 64, height: 64, fill: 100))
        streamer.consume(frame, time: 0)
        active = true
        streamer.consume(frame, time: 1)
        streamer.consume(frame, time: 2)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sent, 1, "second frame waits for the first to be delivered")
    }

    func testSettingsPersistNewOptions() {
        let defaults = UserDefaults(suiteName: "SupportTests-\(UUID().uuidString)")!
        let a = SettingsStore(defaults: defaults)
        XCTAssertFalse(a.saveShotsToPhotos)
        XCTAssertEqual(a.maxRecordingMinutes, 3)
        a.saveShotsToPhotos = true
        a.saveSessionToPhotos = true
        a.maxRecordingMinutes = 5
        let b = SettingsStore(defaults: defaults)
        XCTAssertTrue(b.saveShotsToPhotos)
        XCTAssertTrue(b.saveSessionToPhotos)
        XCTAssertEqual(b.maxRecordingSeconds, 300)
    }

    func testBallDiameterRefinement() {
        var luma = ArrayLuma(width: 200, height: 200, fill: 60)
        luma.fillCircle(center: CGPoint(x: 100, y: 100), radius: 10, value: 230)
        XCTAssertTrue(BallMeasure.looksLikeBall(around: CGPoint(x: 100, y: 100), boxDiameter: 24, in: luma))
        XCTAssertEqual(BallMeasure.refinedDiameter(around: CGPoint(x: 100, y: 100), boxDiameter: 24, in: luma),
                       20, accuracy: 1.5, "measured from the disk, not the loose detector box")
        XCTAssertFalse(BallMeasure.looksLikeBall(around: CGPoint(x: 40, y: 40), boxDiameter: 24, in: luma),
                       "no bright disk there")
    }

    func testDuplicateDetectionsCollapse() {
        let a = BallCandidate(center: CGPoint(x: 100, y: 100), diameterPx: 20, confidence: 0.6)
        let b = BallCandidate(center: CGPoint(x: 108, y: 100), diameterPx: 20, confidence: 0.5)
        let c = BallCandidate(center: CGPoint(x: 200, y: 100), diameterPx: 20, confidence: 0.4)
        XCTAssertEqual(BallMeasure.deduplicated([a, b, c]), [a, c])
    }

    func testCalibrationFromBall() {
        let track = BallTrack(center: .zero, diameterPx: 21.335, frameWidth: 1, frameHeight: 1, confidence: 1, lockedAt: 0)
        let calibration = Calibration(ball: track)
        XCTAssertTrue(calibration.isCalibrated)
        XCTAssertEqual(calibration.pixelsPerMeter, 500, accuracy: 0.5)
    }

    func testSlowMotionFormatScoringPrefers240() {
        XCTAssertGreaterThan(SlowMotionFormatPicker.score(fps: 240, lines: 720, fullRange: false),
                             SlowMotionFormatPicker.score(fps: 120, lines: 1080, fullRange: true))
        XCTAssertGreaterThan(SlowMotionFormatPicker.score(fps: 240, lines: 1080, fullRange: false),
                             SlowMotionFormatPicker.score(fps: 240, lines: 720, fullRange: true))
    }
}
