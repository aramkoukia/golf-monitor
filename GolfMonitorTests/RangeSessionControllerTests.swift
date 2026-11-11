import XCTest
@testable import GolfMonitor

/// The range state machine with a fake camera and processor: phone and watch
/// commands, rejections, time limit, backgrounding and remote state.
@MainActor
final class RangeSessionControllerTests: XCTestCase {
    final class FakeCamera: RecordingDevice {
        var isReadyToRecord = true
        var frameRate: Double = 240
        var isRecording = false
        var startError: Error?
        var stopResult: Result<RecordedVideo, Error> = .success(
            RecordedVideo(url: URL(fileURLWithPath: "/tmp/none.mov"), duration: 5, fps: 240, startTime: 10, endTime: 15))
        private(set) var cancelled = false

        func startRecording() throws {
            if let startError { throw startError }
            isRecording = true
            isReadyToRecord = false
        }

        func stopRecording() async throws -> RecordedVideo {
            isRecording = false
            isReadyToRecord = true
            return try stopResult.get()
        }

        func cancelRecording() {
            isRecording = false
            isReadyToRecord = true
            cancelled = true
        }
    }

    final class FakeProcessor: SessionProcessing {
        var outcome: SessionOutcome?
        var error: Error?
        var delay: UInt64 = 0
        private(set) var received: [(RecordedSession, SessionContext)] = []

        func process(_ session: RecordedSession, context: SessionContext,
                     progress: @escaping @MainActor (ProcessingProgress) -> Void) async throws -> SessionOutcome {
            received.append((session, context))
            progress(ProcessingProgress(step: .measuring, fraction: 0.5, detail: "Measuring"))
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            if let error { throw error }
            return outcome!
        }
    }

    final class FakeAnnouncer: ShotAnnouncing {
        var spoken: [String] = []
        func announce(_ text: String) { spoken.append(text) }
    }

    private var root: URL!
    private var defaults: UserDefaults!
    private var store: ShotStore!
    private var settings: SettingsStore!
    private var camera: FakeCamera!
    private var processor: FakeProcessor!
    private var controller: RangeSessionController!
    private var changes = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "RangeSessionControllerTests-\(UUID().uuidString)")
        store = ShotStore(rootDirectory: root)
        settings = SettingsStore(defaults: defaults)
        camera = FakeCamera()
        processor = FakeProcessor()
        processor.outcome = Self.outcome(store: store)
        controller = RangeSessionController(camera: camera, monitor: SceneMonitor(locator: SceneMonitorTests.FakeLocator([])),
                                            processor: processor, settings: settings, store: store, defaults: defaults)
        controller.beginBackgroundWork = { {} }
        controller.onChange = { [unowned self] in changes += 1 }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    static func outcome(store: ShotStore) -> SessionOutcome {
        let shot = store.addShot(Shot(club: .iron7, ballSpeedMph: 120, clubSpeedMph: 88, launchAngleDeg: 17,
                                      carryYards: 165, apexYards: 30, hangTimeS: 6, smashFactor: 0,
                                      tempoRatio: 3.1, offlineYards: 0), clipURL: nil, analysis: nil, thumbnail: nil)
        let analysis = SwingAnalysis(fps: 240, frameWidth: 1080, frameHeight: 1920, duration: 3.8,
                                     cameraView: .faceOn, handedness: .right)
        return SessionOutcome(shots: [shot], featured: FeaturedShot(shot: shot, analysis: analysis),
                              swingsSeen: 3, practiceSwings: 2, struckCount: 1, savedToPhotos: true, warnings: [])
    }

    private func waitForPhase(_ predicate: (RangeSessionController.Phase) -> Bool, timeout: Double = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(controller.phase), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Tests

    func testStartStopProducesAReview() async {
        XCTAssertTrue(controller.start(origin: .phone).accepted)
        XCTAssertTrue(controller.phase.isRecording)
        XCTAssertTrue(camera.isRecording)
        XCTAssertNotNil(store.activeSessionID, "a library session is opened on first recording")

        XCTAssertTrue(controller.stop(origin: .phone).accepted)
        XCTAssertEqual(controller.phase, .processing)
        await waitForPhase { $0 == .review }
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(controller.outcome?.struckCount, 1)
        XCTAssertEqual(processor.received.first?.1.club, controller.club)
        XCTAssertGreaterThan(changes, 3)

        controller.dismissResult()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.outcome)
    }

    func testLiveTimelineIsHandedToTheProcessor() async {
        controller.start(origin: .phone)
        controller.stop(origin: .phone)
        await waitForPhase { $0 == .review }
        let session = processor.received.first?.0
        XCTAssertNotNil(session?.timeline)
        XCTAssertEqual(session?.fps, 240)
        camera.stopResult = .success(RecordedVideo(url: URL(fileURLWithPath: "/tmp/sim.mov"), duration: 2, fps: 240,
                                                   startTime: 0, endTime: 2, hasLiveTimeline: false))
        controller.dismissResult()
        controller.start(origin: .phone)
        controller.stop(origin: .phone)
        await waitForPhase { $0 == .review }
        XCTAssertNil(processor.received.last?.0.timeline, "simulated camera: scan the file instead")
    }

    func testProcessorIsToldWhereStopWasPressed() async {
        for (origin, atPhone) in [(RangeSessionController.Origin.phone, true), (.watch, false), (.system, false)] {
            controller.start(origin: .phone)
            controller.stop(origin: origin)
            await waitForPhase { $0 == .review }
            XCTAssertEqual(processor.received.last?.1.stoppedAtPhone, atPhone, "\(origin)")
            controller.dismissResult()
        }
        controller.start(origin: .watch)
        controller.setAppActive(false)
        await waitForPhase { $0 == .review }
        XCTAssertEqual(processor.received.last?.1.stoppedAtPhone, true, "leaving the app means someone was at the phone")
    }

    func testEachNewBallLockIsCountedOnceAndPublished() {
        func lock(_ id: UUID, present: Bool = true) -> SceneSnapshot.Lock {
            SceneSnapshot.Lock(id: id, center: CGPoint(x: 0.5, y: 0.6), diameter: 0.02, isPresent: present)
        }
        let teed = UUID(), loose = UUID(), next = UUID()
        controller.updateScene(SceneSnapshot(locks: [lock(teed)]))
        XCTAssertEqual(controller.currentRemoteState().ballLocksSeen, 1)

        let published = changes
        controller.updateScene(SceneSnapshot(locks: [lock(teed), lock(loose)]))
        XCTAssertEqual(controller.ballLocksSeen, 2)
        XCTAssertGreaterThan(changes, published, "a new lock is sent even though a ball was already locked")

        controller.updateScene(SceneSnapshot(locks: [lock(teed, present: false), lock(loose)]))
        controller.updateScene(SceneSnapshot(locks: [lock(teed), lock(loose)]))
        XCTAssertEqual(controller.ballLocksSeen, 2, "a hidden ball coming back is not a new lock")

        controller.updateScene(SceneSnapshot(locks: [lock(next, present: false)]))
        XCTAssertEqual(controller.ballLocksSeen, 2, "counted once it's actually visible")
        controller.updateScene(SceneSnapshot(locks: [lock(next)]))
        XCTAssertEqual(controller.ballLocksSeen, 3)
    }

    func testRejectsInvalidCommands() {
        XCTAssertFalse(controller.stop(origin: .watch).accepted)
        camera.isReadyToRecord = false
        controller.cameraUnavailableReason = { "Camera starting…" }
        let rejected = controller.start(origin: .watch)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.reason, "Camera starting…")
        XCTAssertEqual(controller.lastRejection, "Camera starting…")
        camera.isReadyToRecord = true
        XCTAssertTrue(controller.start(origin: .watch).accepted)
        XCTAssertEqual(controller.start(origin: .watch).reason, "Already recording.")
    }

    func testCannotStartInBackground() {
        controller.setAppActive(false)
        XCTAssertFalse(controller.start(origin: .watch).accepted)
        XCTAssertEqual(controller.currentRemoteState().phase, .notReady)
    }

    func testGoingToBackgroundWhileRecordingKeepsTheRecording() async {
        controller.start(origin: .watch)
        controller.setAppActive(false)
        XCTAssertEqual(controller.phase, .processing, "stopped and analyzing, not discarded")
        await waitForPhase { $0 == .review }
        XCTAssertEqual(controller.phase, .review)
    }

    func testCameraStartFailureIsReported() {
        camera.startError = SessionError.recordingFailed("disk full")
        let result = controller.start(origin: .phone)
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCancelDiscardsRecording() {
        controller.start(origin: .phone)
        XCTAssertTrue(controller.cancel().accepted)
        XCTAssertTrue(camera.cancelled)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(processor.received.isEmpty)
    }

    func testCancelDuringProcessing() async {
        processor.delay = 2_000_000_000
        controller.start(origin: .phone)
        controller.stop(origin: .phone)
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.phase, .idle, "a late result doesn't resurrect the review")
    }

    func testProcessingErrorShowsFailureThenRecovers() async {
        processor.error = SessionError.noMotionFound
        controller.start(origin: .phone)
        controller.stop(origin: .phone)
        await waitForPhase { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(controller.phase, .failed(SessionError.noMotionFound.localizedDescription))
        XCTAssertEqual(controller.currentRemoteState().phase, .error)
        XCTAssertTrue(controller.start(origin: .watch).accepted, "start from the error screen")
    }

    func testTimeLimitStopsAutomatically() async {
        controller.recordingLimitOverride = 0.2
        controller.start(origin: .phone)
        await waitForPhase { $0 != .idle && !$0.isRecording }
        XCTAssertFalse(controller.phase.isRecording)
    }

    func testWatchCommandsDriveTheSameStateMachine() async {
        XCTAssertTrue(controller.handleRemote(RemoteRequest(command: .start)).accepted)
        let recording = controller.handleRemote(RemoteRequest(command: .requestState)).state
        XCTAssertEqual(recording?.phase, .recording)
        XCTAssertNotNil(recording?.recordingElapsed)

        XCTAssertTrue(controller.handleRemote(RemoteRequest(command: .stop)).accepted)
        await waitForPhase { $0 == .review }
        let result = controller.currentRemoteState()
        XCTAssertEqual(result.phase, .result)
        XCTAssertEqual(result.lastShot?.carry ?? 0, 165, accuracy: 0.5)
        XCTAssertEqual(result.lastShot?.practiceSwings, 2)
        XCTAssertEqual(result.lastShot?.distanceUnit, "YDS")
        XCTAssertTrue(result.lastShot?.savedToPhotos ?? false)

        XCTAssertTrue(controller.handleRemote(RemoteRequest(command: .dismissResult)).accepted)
        XCTAssertEqual(controller.currentRemoteState().phase, .ready)
    }

    func testWatchClubSelection() {
        XCTAssertTrue(controller.handleRemote(RemoteRequest(command: .selectClub, argument: "7 Iron")).accepted)
        XCTAssertEqual(controller.club, .iron7)
        XCTAssertEqual(defaults.string(forKey: RangeSessionController.clubKey), "7 Iron", "remembered")
        XCTAssertFalse(controller.handleRemote(RemoteRequest(command: .selectClub, argument: "Putter")).accepted)
        XCTAssertEqual(controller.currentRemoteState().clubShort, "7i")
    }

    func testRemoteStateRevisionsIncrease() {
        let a = controller.currentRemoteState()
        controller.start(origin: .phone)
        let b = controller.currentRemoteState()
        XCTAssertGreaterThan(b.revision, a.revision)
        XCTAssertTrue(b.supersedes(a))
        XCTAssertFalse(a.supersedes(b))
    }

    func testResultIsAnnouncedWhenVoiceIsOn() async {
        let announcer = FakeAnnouncer()
        controller.announcer = announcer
        settings.voiceReadout = true
        controller.start(origin: .phone)
        controller.stop(origin: .phone)
        await waitForPhase { $0 == .review }
        XCTAssertEqual(announcer.spoken, ["165 yards carry. Ball speed 120."])
    }

    func testMetricUnitsInSummary() async {
        settings.distanceUnit = .meters
        settings.speedUnit = .kmh
        controller.start(origin: .phone)
        controller.stop(origin: .phone)
        await waitForPhase { $0 == .review }
        let summary = controller.currentRemoteState().lastShot
        XCTAssertEqual(summary?.carry ?? 0, 165 * 0.9144, accuracy: 0.5)
        XCTAssertEqual(summary?.ballSpeed ?? 0, 120 * 1.60934, accuracy: 0.5)
        XCTAssertEqual(summary?.distanceUnit, "M")
    }
}
