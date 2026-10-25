import XCTest
@testable import GolfMonitor

/// Smoke test for the interim analyzer (W2 replaces this with real tests).
final class AnalysisInterimTests: XCTestCase {
    func testInterimAnalyzerProducesPosesAndPhases() async throws {
        let src = try XCTUnwrap(MLPipelineTests.fixtureURL("faceon_driver"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: src, to: tmp)
        let out = try await SwingAnalyzer().analyze(AnalysisRequest(clipURL: tmp, club: .driver, cameraView: .faceOn,
                                                                   handedness: .right, calibration: nil))
        print("POSES \(out.analysis.poses.count) PHASES \(out.analysis.phases.map { "\($0.phase.rawValue)@\(String(format: "%.2f", $0.t))" }) TEMPO \(out.analysis.metric("tempo.ratio")?.value ?? -1)")
        XCTAssertGreaterThan(out.analysis.poses.count, 30)
        XCTAssertEqual(out.analysis.phases.count, 8)
        let tempo = try XCTUnwrap(out.analysis.metric("tempo.ratio")?.value)
        XCTAssertTrue((1.5...5).contains(tempo), "tempo \(tempo)")
        XCTAssertNotNil(out.thumbnail)
    }
}
