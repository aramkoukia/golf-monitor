import XCTest
import AVFoundation
import Vision
import CoreML
@testable import GolfMonitor

/// Verifies the simulator can run the on-device vision stack against the
/// bundled CC0 swing fixtures (so analysis tests are meaningful here).
final class VisionProbeTests: XCTestCase {

    private func frame(_ name: String, at seconds: Double) async throws -> CGImage {
        try await MLPipelineTests.frame(name, at: seconds)
    }

    func testBodyPoseRunsOnFixture() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision body pose needs the Neural Engine; unavailable in the simulator")
        #else
        let image = try await frame("faceon_driver", at: 0.2)
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let obs = try XCTUnwrap(request.results?.first, "no body detected")
        let pts = try obs.recognizedPoints(.all)
        let confident = pts.values.filter { $0.confidence > 0.3 }
        XCTAssertGreaterThan(confident.count, 10)
        #endif
    }

    func testCoreMLDetectorRunsOnFixture() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "COCODetector", withExtension: "mlmodelc"))
        let model = try MLModel(contentsOf: url)
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        let image = try await frame("faceon_driver", at: 0.2)
        try VNImageRequestHandler(cgImage: image).perform([request])
        XCTAssertNotNil(request.results?.first)
    }
}
