import CoreGraphics
import CoreImage
import CoreML
import Foundation
import Vision

/// Estimates the golfer's 2D body pose in one upright frame. Points are
/// returned NORMALIZED (0...1, top-left origin) in the full frame.
protocol PoseEstimating: AnyObject {
    var name: String { get }
    func pose(in image: CIImage, t: Double) -> PoseSample?
}

enum PoseEstimatorFactory {
    /// Apple Vision (Neural Engine) on device; YOLO11n-pose Core ML where
    /// Vision's body-pose request is unavailable (e.g. the Simulator).
    static func make() -> PoseEstimating? {
        #if targetEnvironment(simulator)
        return CoreMLPoseEstimator()
        #else
        if VisionPoseEstimator.isSupported { return VisionPoseEstimator() }
        return CoreMLPoseEstimator()
        #endif
    }
}

// MARK: - Apple Vision

final class VisionPoseEstimator: PoseEstimating {
    let name = "Vision body pose"

    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private static let map: [(VNHumanBodyPoseObservation.JointName, BodyJoint)] = [
        (.nose, .nose), (.leftEye, .leftEye), (.rightEye, .rightEye),
        (.leftEar, .leftEar), (.rightEar, .rightEar), (.neck, .neck),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.root, .root), (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]

    func pose(in image: CIImage, t: Double) -> PoseSample? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else { return nil }
        // Several people in frame (range neighbours): keep the largest body.
        let best = observations.max { area($0) < area($1) }!
        guard let points = try? best.recognizedPoints(.all) else { return nil }
        var out: [BodyJoint: (point: CGPoint, confidence: Float)] = [:]
        for (vn, joint) in Self.map {
            guard let p = points[vn], p.confidence > 0 else { continue }
            // Vision is bottom-left origin.
            out[joint] = (CGPoint(x: p.location.x, y: 1 - p.location.y), p.confidence)
        }
        return out.isEmpty ? nil : PoseSample(t: t, points: out)
    }

    private func area(_ o: VNHumanBodyPoseObservation) -> CGFloat {
        guard let pts = try? o.recognizedPoints(.all).values.filter({ $0.confidence > 0.2 }), !pts.isEmpty else { return 0 }
        let xs = pts.map(\.location.x), ys = pts.map(\.location.y)
        return (xs.max()! - xs.min()!) * (ys.max()! - ys.min()!)
    }
}

// MARK: - YOLO11n-pose (Core ML)

/// Decodes the raw Ultralytics pose head: output [1, 56, anchors] =
/// 4 box (cx, cy, w, h in input pixels) + 1 person score + 17 × (x, y, vis).
final class CoreMLPoseEstimator: PoseEstimating {
    let name = "YOLO11n-pose"
    private let model: MLModel
    private let pre: ImagePreprocessor
    private let inputName: String
    private let side: Int

    /// COCO-17 keypoint order → BodyJoint. Neck and root are synthesized.
    private static let coco: [BodyJoint] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]

    init?() {
        guard let m = ModelCatalog.shared.model(.golferPose),
              let input = m.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })
        else { return nil }
        model = m
        inputName = input.key
        side = input.value.imageConstraint?.pixelsWide ?? 640
        pre = ImagePreprocessor(side: side)
    }

    /// - Parameter roi: optional source-pixel region around the golfer for a
    ///   higher-resolution pass (e.g. the previous frame's body box, padded).
    func pose(in image: CIImage, t: Double) -> PoseSample? {
        pose(in: image, t: t, roi: nil)
    }

    func pose(in image: CIImage, t: Double, roi: CGRect?) -> PoseSample? {
        guard let (buffer, transform) = pre.letterbox(image, crop: roi),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)]),
              let out = try? model.prediction(from: provider),
              let arr = out.featureNames.lazy.compactMap({ out.featureValue(for: $0)?.multiArrayValue }).first
        else { return nil }
        let shape = arr.shape.map(\.intValue)
        guard shape.count == 3, shape[1] == 56 else { return nil }
        let anchors = shape[2]
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        let f32 = arr.dataType == .float32
        func v(_ ch: Int, _ a: Int) -> Float { f32 ? ptr[ch * anchors + a] : arr[ch * anchors + a].floatValue }

        // Highest-scoring large person (score × sqrt(area) favours the golfer
        // in the foreground over people walking behind).
        var bestA = -1
        var bestScore: Float = 0
        for a in 0..<anchors {
            let s = v(4, a)
            guard s > 0.35 else { continue }
            let rank = s * sqrt(max(v(2, a) * v(3, a), 1))
            if rank > bestScore { bestScore = rank; bestA = a }
        }
        guard bestA >= 0 else { return nil }

        let W = image.extent.width, H = image.extent.height
        var points: [BodyJoint: (point: CGPoint, confidence: Float)] = [:]
        for (k, joint) in Self.coco.enumerated() {
            let p = transform.toSource(CGPoint(x: CGFloat(v(5 + 3 * k, bestA)), y: CGFloat(v(6 + 3 * k, bestA))))
            points[joint] = (CGPoint(x: p.x / W, y: p.y / H), v(7 + 3 * k, bestA))
        }
        func mid(_ a: BodyJoint, _ b: BodyJoint) -> (point: CGPoint, confidence: Float)? {
            guard let pa = points[a], let pb = points[b] else { return nil }
            return (CGPoint(x: (pa.point.x + pb.point.x) / 2, y: (pa.point.y + pb.point.y) / 2),
                    min(pa.confidence, pb.confidence))
        }
        points[.neck] = mid(.leftShoulder, .rightShoulder)
        points[.root] = mid(.leftHip, .rightHip)
        return PoseSample(t: t, points: points)
    }
}
