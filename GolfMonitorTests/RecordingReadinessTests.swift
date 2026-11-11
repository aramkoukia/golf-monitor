import XCTest
@testable import GolfMonitor

/// The "Ready to swing" indicator: light, camera view, ball lock and room in
/// front of the ball, plus how it reaches the watch.
@MainActor
final class RecordingReadinessTests: XCTestCase {
    private let check = RecordingReadiness()

    private func scene(balls: [CGFloat] = [], brightness: Float? = 0.45) -> SceneSnapshot {
        SceneSnapshot(locks: balls.map {
            SceneSnapshot.Lock(id: UUID(), center: CGPoint(x: $0, y: 0.7), diameter: 0.02, isPresent: true)
        }, brightness: brightness)
    }

    private func inputs(_ scene: SceneSnapshot, view: CameraView = .faceOn, hand: Handedness = .right,
                        fixedShutter: Bool = true) -> RecordingReadiness.Inputs {
        RecordingReadiness.Inputs(scene: scene, cameraView: view, handedness: hand, fixedShutter: fixedShutter)
    }

    func testReadyWithALockedBallThatHasRoomToFly() {
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.4]))), .ready)
        XCTAssertTrue(RemoteReadiness.ready.isReady)
    }

    func testNoBallLockedIsNotReady() {
        let readiness = check.evaluate(inputs(scene()))
        XCTAssertEqual(readiness, .noBall)
        XCTAssertFalse(readiness.isReady)
    }

    func testBallAtTheEdgeItFliesOutOf() {
        // Right-hander, face-on: the ball flies toward the image's right.
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.85]))), .ballAtEdge)
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.15]))), .ready, "plenty of room to the right")
        // Left-hander: mirrored.
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.15]), hand: .left)), .ballAtEdge)
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.85]), hand: .left)), .ready)
        // Any locked ball with room will do (a loose ball can sit at the edge).
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.9, 0.4]))), .ready)
    }

    func testTooDarkForAFixedShutter() {
        let dark = scene(balls: [0.4], brightness: 0.1)
        XCTAssertEqual(check.evaluate(inputs(dark)), .tooDark)
        XCTAssertEqual(check.evaluate(inputs(dark, fixedShutter: false)), .ready, "Auto exposure brightens itself")
        XCTAssertEqual(check.evaluate(inputs(scene(balls: [0.4], brightness: nil))), .ready, "no frame yet")
        XCTAssertEqual(check.evaluate(inputs(dark, view: .downTheLine)), .tooDark, "pose needs light too")
    }

    func testDarknessHasHysteresis() {
        let borderline = scene(balls: [0.4], brightness: check.darkBelow + 0.01)
        XCTAssertEqual(check.evaluate(inputs(borderline)), .ready)
        XCTAssertEqual(check.evaluate(inputs(borderline), previous: .tooDark), .tooDark, "must get clearly brighter")
        let bright = scene(balls: [0.4], brightness: check.darkBelow + check.darkHysteresis + 0.01)
        XCTAssertEqual(check.evaluate(inputs(bright), previous: .tooDark), .ready)
    }

    func testDownTheLineIsReadyForSwingAnalysis() {
        XCTAssertEqual(check.evaluate(inputs(scene(), view: .downTheLine)), .readySwingOnly)
        XCTAssertTrue(RemoteReadiness.readySwingOnly.isReady)
    }

    func testEveryStateHasWordsForBothScreens() {
        for readiness in RemoteReadiness.allCases {
            XCTAssertFalse(readiness.label.isEmpty)
            XCTAssertFalse(readiness.hint.isEmpty)
            XCTAssertLessThanOrEqual(readiness.label.count, 20, "fits the watch pill: \(readiness.label)")
        }
    }

    func testWatchReadyScreenFollowsReadiness() {
        var state = RemoteState.placeholder()
        state.phase = .ready
        state.readiness = .ready
        XCTAssertEqual(RemoteScreenModel.make(state: state, reachable: true).title, "Ready to swing")
        state.readiness = .ballAtEdge
        let screen = RemoteScreenModel.make(state: state, reachable: true)
        XCTAssertEqual(screen.title, "Ready")
        XCTAssertEqual(screen.detail, RemoteReadiness.ballAtEdge.hint)
        XCTAssertEqual(screen.primary, .start, "advisory: you can always start")
        state.readiness = nil
        state.ballLocked = true
        XCTAssertEqual(RemoteScreenModel.make(state: state, reachable: true).title, "Ball locked", "older phone")
    }

    func testReadinessRoundTripsToTheWatch() {
        var state = RemoteState.placeholder()
        state.readiness = .tooDark
        let message = RemoteWire.message(state, kind: .state)
        XCTAssertEqual(RemoteWire.decode(RemoteState.self, from: message, kind: .state)?.readiness, .tooDark)
    }

    func testSceneMonitorReportsBrightness() {
        let monitor = SceneMonitor(locator: SceneMonitorTests.FakeLocator([]))
        let frame = SceneMonitorTests.pixelBuffer(ArrayLuma(width: 64, height: 64, fill: 51))
        monitor.ingest(frame, time: 0)
        XCTAssertEqual(monitor.currentSnapshot.brightness ?? -1, 0.2, accuracy: 0.005)
        monitor.reset()
        XCTAssertNil(monitor.currentSnapshot.brightness)
    }
}
