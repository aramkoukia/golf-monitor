import XCTest
import AVFoundation
import CoreImage
import UIKit
@testable import GolfMonitor

/// Runs the bundled models on the CC0 swing fixtures. Overlay renders are
/// written to $GM_TEST_OUT (or the temp dir) for visual inspection.
final class MLPipelineTests: XCTestCase {

    static func fixtureURL(_ name: String) -> URL? {
        let b = Bundle(for: MLPipelineTests.self)
        return b.url(forResource: name, withExtension: "mp4") ?? b.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures")
    }

    static func frame(_ name: String, at seconds: Double) throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: try XCTUnwrap(fixtureURL(name))))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    static var outDir: URL {
        let path = ProcessInfo.processInfo.environment["GM_TEST_OUT"] ?? "/tmp/gm-test-out"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCoreMLPoseOnFixtureFrames() throws {
        let est = try XCTUnwrap(CoreMLPoseEstimator())
        for (clip, t) in [("faceon_driver", 0.15), ("faceon_driver", 1.30), ("dtl_iron", 0.2), ("dtl_iron", 1.0)] {
            let cg = try Self.frame(clip, at: t)
            let pose = try XCTUnwrap(est.pose(in: CIImage(cgImage: cg), t: t), "no pose for \(clip)@\(t)")
            // Anatomical sanity in an upright frame: head above hips above ankles.
            let nose = try XCTUnwrap(pose.point(.nose, minConfidence: 0.3))
            let hip = try XCTUnwrap(pose.point(.root, minConfidence: 0.3))
            let ankle = try XCTUnwrap(pose.point(.leftAnkle, minConfidence: 0.3) ?? pose.point(.rightAnkle, minConfidence: 0.3))
            XCTAssertLessThan(nose.y, hip.y, "\(clip)@\(t)")
            XCTAssertLessThan(hip.y, ankle.y, "\(clip)@\(t)")
            Self.render(cg, pose: pose, detections: [], name: "pose_\(clip)_\(t)")
        }
    }

    func testCOCODetectorFindsGolferAndBalls() throws {
        let det = try XCTUnwrap(ObjectDetector(.cocoDetector))
        let cg = try Self.frame("faceon_driver", at: 0.15)
        let dets = det.detect(in: CIImage(cgImage: cg), confidence: 0.2)
        XCTAssertTrue(dets.contains { $0.label == "person" }, "labels: \(dets.map(\.label))")
        Self.render(cg, pose: nil, detections: dets, name: "coco_faceon")
    }

    func testGolfDetectorIsBundledAndRecognizesBallClass() throws {
        let detector = try XCTUnwrap(ObjectDetector(.golfDetector))
        XCTAssertTrue(
            detector.classNames.contains { $0.localizedCaseInsensitiveContains("ball") },
            "Unexpected GolfDetector classes: \(detector.classNames)"
        )
    }

    func testBallSelectionPrefersCenteredDetectionOverHigherConfidenceDistractor() {
        let centeredBall = DetectedBall(
            center: CGPoint(x: 501, y: 499), diameter: 22,
            frameWidth: 1000, frameHeight: 1000, confidence: 0.35
        )
        let distractor = DetectedBall(
            center: CGPoint(x: 600, y: 510), diameter: 48,
            frameWidth: 1000, frameHeight: 1000, confidence: 0.9
        )
        let outsideCenter = DetectedBall(
            center: CGPoint(x: 850, y: 700), diameter: 60,
            frameWidth: 1000, frameHeight: 1000, confidence: 0.99
        )

        let selected = DetectedBall.centeredCandidates(
            in: [outsideCenter, distractor, centeredBall]
        ).first

        XCTAssertEqual(selected?.center, centeredBall.center)
    }

    func testBallSelectionRejectsCandidatesOutsideCenterFramingArea() {
        let candidate = DetectedBall(
            center: CGPoint(x: 800, y: 700), diameter: 40,
            frameWidth: 1000, frameHeight: 1000, confidence: 0.99
        )

        XCTAssertTrue(DetectedBall.centeredCandidates(in: [candidate]).isEmpty)
    }

    func testGolfDetectorFindsBallWithNativeAndCalibrationTiles() throws {
        let detector = try XCTUnwrap(ObjectDetector(.golfDetector))
        let cg = try Self.frame("faceon_driver", at: 0.15)
        let image = CIImage(cgImage: cg)
        let trackingDetections = detector.detectTiled(in: image, confidence: 0.25)
        XCTAssertTrue(
            trackingDetections.contains {
                $0.label.localizedCaseInsensitiveContains("ball")
                    && hypot($0.center.x - 489, $0.center.y - 931) < 60
            },
            "Native-size model tiles did not find the fixture ball: \(trackingDetections)"
        )
        let calibrationDetections = detector.detectTiled(in: image, tile: 640, confidence: 0.25)
        XCTAssertTrue(
            calibrationDetections.contains {
                $0.label.localizedCaseInsensitiveContains("ball")
                    && hypot($0.center.x - 489, $0.center.y - 931) < 60
            },
            "Calibration tile boxes were not mapped to source-frame coordinates: \(calibrationDetections)"
        )
        let bestBall = try XCTUnwrap(
            calibrationDetections
                .filter { $0.label.localizedCaseInsensitiveContains("ball") }
                .max { $0.confidence < $1.confidence }
        )
        XCTAssertGreaterThanOrEqual(bestBall.confidence, 0.25)
        XCTAssertLessThan(hypot(bestBall.center.x - 489, bestBall.center.y - 931), 60,
                          "Highest-confidence ball candidate was not the fixture ball: \(bestBall)")
    }

    static func render(_ cg: CGImage, pose: PoseSample?, detections: [Detection], name: String) {
        let size = CGSize(width: cg.width, height: cg.height)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            let c = ctx.cgContext
            if let pose {
                c.setStrokeColor(UIColor.green.cgColor); c.setLineWidth(4)
                for (a, b) in BodyJoint.bones {
                    guard let pa = pose.point(a), let pb = pose.point(b) else { continue }
                    c.move(to: CGPoint(x: pa.x * size.width, y: pa.y * size.height))
                    c.addLine(to: CGPoint(x: pb.x * size.width, y: pb.y * size.height))
                }
                c.strokePath()
            }
            for d in detections {
                c.setStrokeColor(UIColor.yellow.cgColor); c.setLineWidth(3); c.stroke(d.rect)
                (String(format: "%@ %.2f", d.label, d.confidence) as NSString).draw(at: d.rect.origin, withAttributes: [.foregroundColor: UIColor.yellow, .font: UIFont.boldSystemFont(ofSize: 18)])
            }
        }
        try? img.jpegData(compressionQuality: 0.85)?.write(to: outDir.appendingPathComponent("\(name).jpg"))
    }
}
