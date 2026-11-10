import XCTest
@testable import GolfMonitor

/// End-to-end: a recorded session (still setup → practice swing → still →
/// real strike → still) through scanning, shot finding, clip cutting,
/// auto-calibration, on-device analysis and saving.
@MainActor
final class SessionPipelineTests: XCTestCase {
    final class FakePhotos: PhotoLibrarySaving {
        var saved: [URL] = []
        var error: Error?
        func saveVideo(at url: URL) async throws {
            if let error { throw error }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            saved.append(url)
        }
    }

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func copyFixture(_ name: String) throws -> URL {
        let src = try XCTUnwrap(MLPipelineTests.fixtureURL(name))
        let dst = root.appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    func testSessionWithPracticeSwingSavesOneMeasuredShot() async throws {
        let store = ShotStore(rootDirectory: root)
        let photos = FakePhotos()
        let processor = SessionProcessor(store: store, photos: photos)
        let video = try copyFixture("session_faceon_driver")
        var steps: [ProcessingProgress.Step] = []

        let outcome = try await processor.process(
            RecordedSession(videoURL: video, duration: 8.98, fps: 240, timeline: nil),
            context: SessionContext(club: .driver, cameraView: .faceOn, handedness: .right,
                                    saveShotsToPhotos: true, saveSessionToPhotos: false)
        ) { steps.append($0.step) }

        XCTAssertEqual(outcome.struckCount, 1)
        XCTAssertEqual(outcome.practiceSwings, 1)
        XCTAssertEqual(outcome.shots.count, 1)
        let shot = try XCTUnwrap(outcome.featured?.shot)
        XCTAssertTrue(shot.hasLaunchData, outcome.featured?.metricsError ?? "")
        XCTAssertTrue((55...100).contains(shot.ballSpeedMph), "ball speed \(shot.ballSpeedMph)")
        XCTAssertTrue((12...35).contains(shot.launchAngleDeg), "launch \(shot.launchAngleDeg)")
        XCTAssertGreaterThan(shot.carryYards, 40)
        XCTAssertGreaterThan(shot.clubSpeedMph, 0)
        XCTAssertNotNil(shot.descentAngleDeg)
        XCTAssertEqual(shot.impactTimeInClip ?? 0, ShotFinder.Config().preRoll, accuracy: 0.08)
        XCTAssertTrue((1.5...4.5).contains(shot.tempoRatio), "tempo \(shot.tempoRatio)")
        XCTAssertGreaterThanOrEqual(outcome.featured?.analysis.ballTrack.count ?? 0, 3)
        XCTAssertNotNil(outcome.featured?.tracerImage)
        XCTAssertTrue(shot.hasMedia)
        XCTAssertNotNil(store.clipURL(for: shot.id))
        XCTAssertNotNil(store.analysis(for: shot.id))
        XCTAssertEqual(photos.saved.count, 1, "shot clip saved to Photos")
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path), "full recording is deleted afterwards")
        XCTAssertEqual(steps.first, .finding)
        XCTAssertEqual(steps.last, .saving)
        XCTAssertEqual(steps, steps.sorted(), "steps only move forward")
        XCTAssertTrue(outcome.savedToPhotos)
        XCTAssertTrue(outcome.warnings.isEmpty, "\(outcome.warnings)")
    }

    func testPhotosFailureIsAWarningNotAnError() async throws {
        let store = ShotStore(rootDirectory: root)
        let photos = FakePhotos()
        photos.error = PhotoLibrarySaver.SaveError.accessDenied
        let outcome = try await SessionProcessor(store: store, photos: photos).process(
            RecordedSession(videoURL: try copyFixture("session_faceon_driver"), duration: 8.98, fps: 240, timeline: nil),
            context: SessionContext(club: .driver, cameraView: .faceOn, handedness: .right,
                                    saveShotsToPhotos: true, saveSessionToPhotos: true)) { _ in }
        XCTAssertEqual(store.shots.count, 1)
        XCTAssertFalse(outcome.savedToPhotos)
        XCTAssertEqual(outcome.warnings, [PhotoLibrarySaver.SaveError.accessDenied.localizedDescription])
    }

    func testFullSessionIsSavedToPhotosWhenAsked() async throws {
        let photos = FakePhotos()
        _ = try await SessionProcessor(store: ShotStore(rootDirectory: root), photos: photos).process(
            RecordedSession(videoURL: try copyFixture("session_faceon_driver"), duration: 8.98, fps: 240, timeline: nil),
            context: SessionContext(club: .driver, cameraView: .faceOn, handedness: .right,
                                    saveShotsToPhotos: false, saveSessionToPhotos: true)) { _ in }
        XCTAssertEqual(photos.saved.count, 1)
    }

    func testDownTheLineSessionIsSavedAsSwingAnalysis() async throws {
        let store = ShotStore(rootDirectory: root)
        let outcome = try await SessionProcessor(store: store, photos: FakePhotos()).process(
            RecordedSession(videoURL: try copyFixture("session_dtl_iron"), duration: 4.7, fps: 240, timeline: nil),
            context: SessionContext(club: .iron7, cameraView: .downTheLine, handedness: .right,
                                    saveShotsToPhotos: false, saveSessionToPhotos: false)) { _ in }
        let shot = try XCTUnwrap(outcome.featured?.shot)
        XCTAssertFalse(shot.hasLaunchData)
        XCTAssertEqual(shot.cameraView, .downTheLine)
        XCTAssertNotNil(outcome.featured?.metricsError)
        XCTAssertEqual(store.shots.count, 1)
    }

    func testStillVideoHasNothingToAnalyze() async throws {
        // 1.5 s of the first frame only: no swing.
        let src = try copyFixture("faceon_driver")
        let still = try await ClipExporter.export(from: src, start: 0, end: 0.04,
                                                  to: root.appendingPathComponent("still.mov"))
        do {
            _ = try await SessionProcessor(store: ShotStore(rootDirectory: root), photos: FakePhotos()).process(
                RecordedSession(videoURL: still, duration: 0.04, fps: 240, timeline: nil),
                context: SessionContext(club: .driver, cameraView: .faceOn, handedness: .right,
                                        saveShotsToPhotos: false, saveSessionToPhotos: false)) { _ in }
            XCTFail("expected noMotionFound")
        } catch {
            XCTAssertEqual(error as? SessionError, .noMotionFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: still.path), "recording cleaned up on failure too")
    }
}
