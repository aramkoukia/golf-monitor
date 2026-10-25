import XCTest
import AVFoundation
import Vision
import CoreML
@testable import GolfMonitor

/// Verifies the simulator can run the on-device vision stack against the
/// bundled CC0 swing fixtures (so analysis tests are meaningful here).
final class VisionProbeTests: XCTestCase {

    private func frame(_ name: String, at seconds: Double) throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4", subdirectory: nil)
            ?? Bundle(for: Self.self).url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    func testBodyPoseRunsOnFixture() throws {
        let image = try frame("faceon_driver", at: 0.2)
        let request = VNDetectHumanBodyPoseRequest()
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision body pose needs the Neural Engine; unavailable in the simulator")
        #endif
        try VNImageRequestHandler(cgImage: image).perform([request])
        let obs = try XCTUnwrap(request.results?.first, "no body detected")
        let pts = try obs.recognizedPoints(.all)
        let confident = pts.values.filter { $0.confidence > 0.3 }
        print("POSE joints confident: \(confident.count) / \(pts.count)")
        XCTAssertGreaterThan(confident.count, 10)
    }

    func testCoreMLDetectorRunsOnFixture() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "COCODetector", withExtension: "mlmodelc"))
        let model = try MLModel(contentsOf: url)
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: try frame("faceon_driver", at: 0.2)).perform([request])
        XCTAssertNotNil(request.results?.first)
    }
}
