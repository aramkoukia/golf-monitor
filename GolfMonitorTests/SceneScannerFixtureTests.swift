import XCTest
@testable import GolfMonitor

/// The real on-device detector + scene monitor + shot finder over 240 fps
/// fixtures. `session_faceon_driver` is built from the CC0 clip: 2 s still
/// setup → practice swing (teed ball stays) → 1.5 s still → real strike
/// (impact ≈ 6.21 s) → 2 s still finish.
final class SceneScannerFixtureTests: XCTestCase {
    func testSessionFindsTheStrikeAndIgnoresThePracticeSwing() async throws {
        let url = try XCTUnwrap(MLPipelineTests.fixtureURL("session_faceon_driver"))
        let timeline = try await SceneScanner.scan(url: url)
        XCTAssertEqual(timeline.duration, 8.98, accuracy: 0.05)

        let result = ShotFinder().analyze(timeline)
        XCTAssertEqual(result.swings.count, 2, "practice swing + real swing")
        XCTAssertEqual(result.practiceSwingCount, 1)
        XCTAssertEqual(result.struckCount, 1)
        let shot = try XCTUnwrap(result.shots.first)
        XCTAssertEqual(shot.impactTime ?? 0, 6.21, accuracy: 0.07)
        let ball = try XCTUnwrap(shot.ball)
        XCTAssertEqual(Double(ball.center.x), 384, accuracy: 6, "the teed ball, not the loose balls nearby")
        XCTAssertEqual(Double(ball.center.y), 865, accuracy: 6)
        XCTAssertEqual(ball.diameterPx, 18, accuracy: 4)
    }

    func testTeedBallIsLockedOnSingleSwingClips() async throws {
        for (name, expected) in [("faceon_driver", CGPoint(x: 385, y: 865)), ("faceon_iron", CGPoint(x: 487, y: 1024))] {
            let url = try XCTUnwrap(MLPipelineTests.fixtureURL(name))
            let timeline = try await SceneScanner.scan(url: url)
            XCTAssertTrue(timeline.balls.contains { hypot($0.center.x - expected.x, $0.center.y - expected.y) < 8 },
                          "\(name): \(timeline.balls.map(\.center))")
        }
    }
}
