import CoreGraphics
import Foundation

// MARK: - Geometry primitives

/// A point in NORMALIZED video coordinates of the upright (display-oriented)
/// frame: x and y in 0...1, origin top-left, y down. Resolution independent,
/// so overlays map straight onto any player size.
struct TrackPoint: Codable, Hashable {
    /// Seconds since the first frame of the clip (real time, not playback).
    var t: Double
    var x: Double
    var y: Double
    /// Detector / tracker confidence 0–1 where available.
    var confidence: Double? = nil
}

/// One sample of the modeled ball flight in METRES (side view):
/// x = downrange distance, y = height, at time t after impact.
struct FlightSample: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
}

// MARK: - Body pose

/// The 19 joints Apple Vision's 2D body-pose request returns, in a fixed
/// order so a pose sample can be stored as a flat array.
enum BodyJoint: Int, CaseIterable, Codable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case neck, leftShoulder, rightShoulder
    case leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip
    case leftKnee, rightKnee, leftAnkle, rightAnkle

    /// Bones drawn by skeleton overlays.
    static let bones: [(BodyJoint, BodyJoint)] = [
        (.leftEar, .leftEye), (.leftEye, .nose), (.nose, .rightEye), (.rightEye, .rightEar),
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}

/// One body-pose observation. `joints` holds BodyJoint.allCases.count
/// entries of (x, y, confidence) flattened: [x0, y0, c0, x1, y1, c1, ...],
/// normalized top-left coordinates like TrackPoint. Confidence 0 = missing.
struct PoseSample: Codable, Hashable {
    var t: Double
    var joints: [Float]

    init(t: Double, joints: [Float]) {
        self.t = t
        self.joints = joints
    }

    init(t: Double, points: [BodyJoint: (point: CGPoint, confidence: Float)]) {
        self.t = t
        var flat = [Float](repeating: 0, count: BodyJoint.allCases.count * 3)
        for (joint, value) in points {
            let i = joint.rawValue * 3
            flat[i] = Float(value.point.x)
            flat[i + 1] = Float(value.point.y)
            flat[i + 2] = value.confidence
        }
        self.joints = flat
    }

    /// Normalized point for a joint, or nil if missing/low confidence.
    func point(_ joint: BodyJoint, minConfidence: Float = 0.2) -> CGPoint? {
        let i = joint.rawValue * 3
        guard i + 2 < joints.count, joints[i + 2] >= minConfidence else { return nil }
        return CGPoint(x: CGFloat(joints[i]), y: CGFloat(joints[i + 1]))
    }

    func confidence(_ joint: BodyJoint) -> Float {
        let i = joint.rawValue * 3
        return i + 2 < joints.count ? joints[i + 2] : 0
    }
}

// MARK: - Swing phases

/// The eight GolfDB swing events (McNally et al., 2019), in swing order.
enum SwingPhase: String, Codable, CaseIterable, Identifiable {
    case address
    case toeUp
    case midBackswing
    case top
    case midDownswing
    case impact
    case midFollowThrough
    case finish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .address: return "Address"
        case .toeUp: return "Takeaway"
        case .midBackswing: return "Halfway Back"
        case .top: return "Top"
        case .midDownswing: return "Delivery"
        case .impact: return "Impact"
        case .midFollowThrough: return "Release"
        case .finish: return "Finish"
        }
    }

    var shortTitle: String {
        switch self {
        case .address: return "ADR"
        case .toeUp: return "TKW"
        case .midBackswing: return "HWB"
        case .top: return "TOP"
        case .midDownswing: return "DEL"
        case .impact: return "IMP"
        case .midFollowThrough: return "REL"
        case .finish: return "FIN"
        }
    }
}

struct SwingPhaseMarker: Codable, Hashable, Identifiable {
    var phase: SwingPhase
    /// Seconds since the first frame of the clip.
    var t: Double
    var confidence: Double = 1
    var id: SwingPhase { phase }
}

// MARK: - Metrics & insights

enum MetricRating: String, Codable {
    /// Inside the tour range.
    case tour
    /// Close to the tour range.
    case good
    /// Clearly outside it.
    case needsWork
    /// No reference range for this metric / view.
    case unrated
}

/// One pose- or timing-derived swing metric (e.g. "Head sway", "Tempo").
struct SwingMetric: Codable, Hashable, Identifiable {
    /// Stable key, e.g. "tempo.ratio", "head.sway". Used for charts/history.
    var id: String
    var name: String
    var value: Double
    /// Display unit: "°", "s", ":1", "cm", "%", "" …
    var unit: String
    var phase: SwingPhase? = nil
    /// Tour reference range for the same camera view, if known.
    var tourRange: ClosedRange<Double>? = nil
    var rating: MetricRating = .unrated
    /// One-line plain-English meaning, shown under the number.
    var explanation: String = ""
}

enum InsightSeverity: String, Codable {
    case positive, info, warning
}

/// A coaching observation generated on-device from the metrics.
struct SwingInsight: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var severity: InsightSeverity
    /// Optional drill suggestion.
    var drill: String? = nil
    var relatedMetricID: String? = nil
}

// MARK: - Analysis bundle

/// Everything the analyzer extracted from one clip. Stored next to the clip in
/// the shot's media folder as analysis.json (see ShotStore).
struct SwingAnalysis: Codable, Hashable {
    static let currentVersion = 2

    var version: Int = SwingAnalysis.currentVersion
    /// Capture frame rate (real time), e.g. 240.
    var fps: Double
    /// Upright frame size in pixels.
    var frameWidth: Int
    var frameHeight: Int
    var duration: Double
    var cameraView: CameraView
    var handedness: Handedness
    /// Scale used for metric distances, from the ball-diameter calibration.
    var pixelsPerMeter: Double? = nil

    var ballTrack: [TrackPoint] = []
    /// Ball position at address/impact (normalized), if found.
    var ballAddress: TrackPoint? = nil
    var impactTime: Double? = nil
    /// Modeled full flight (drag + lift) for the flight slab / tracer.
    var flight: [FlightSample] = []
    var clubTrack: [TrackPoint] = []
    var poses: [PoseSample] = []
    var phases: [SwingPhaseMarker] = []
    var metrics: [SwingMetric] = []
    var insights: [SwingInsight] = []
    /// Human-readable description of the models used, for the About screen
    /// and debugging (e.g. "GolfBallDetector YOLO11n v1 · Vision pose").
    var pipeline: String = ""

    func marker(_ phase: SwingPhase) -> SwingPhaseMarker? {
        phases.first { $0.phase == phase }
    }

    func metric(_ id: String) -> SwingMetric? {
        metrics.first { $0.id == id }
    }

    /// Pose sample nearest to time t.
    func pose(at t: Double) -> PoseSample? {
        guard !poses.isEmpty else { return nil }
        var lo = 0, hi = poses.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if poses[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(poses[lo - 1].t - t) < abs(poses[lo].t - t) { return poses[lo - 1] }
        return poses[lo]
    }
}
