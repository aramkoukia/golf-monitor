import AVFoundation
import CoreImage
import Foundation
import UIKit

// MARK: - API contract (shared by Range, Studio, Library, demo data)

struct AnalysisRequest {
    var clipURL: URL
    var club: Club
    var cameraView: CameraView
    var handedness: Handedness
    /// Ball-diameter calibration. nil → swing-only analysis (no launch numbers).
    var calibration: Calibration?
    /// Seconds from clip start where impact was heard/seen, if known.
    var impactTimeHint: Double? = nil
    /// Phone roll (degrees, + = clockwise) from CoreMotion at capture, used to
    /// correct "vertical" for tilt metrics and launch angle.
    var deviceRollDeg: Double? = nil
    /// Focal length in pixels of the capture format (intrinsics), if known.
    var focalLengthPx: Double? = nil
    /// Exposure duration used for capture (seconds), for blur-aware tracking.
    var exposureDurationS: Double? = nil
    /// Actual capture rate. Nil keeps the analyzer's 240 fps default.
    var captureFPS: Double? = nil
}

struct AnalysisOutput {
    /// Launch numbers, nil when not measurable (down-the-line, ball lost…).
    var metrics: ShotMetrics?
    /// Why launch numbers are missing, user-presentable.
    var metricsError: String?
    var analysis: SwingAnalysis
    /// Poster frame (address position) for lists.
    var thumbnail: UIImage?
    /// Impact-ish frame with the ball/club trails drawn, for sharing.
    var tracerImage: UIImage?
}

/// Offline analysis of one recorded swing clip: ball + club tracking, body
/// pose, swing phases, pose metrics vs tour ranges, coaching insights and
/// launch metrics. Runs off the main thread.
///
/// NOTE: this initial implementation wraps the v1 blob tracker; the analysis
/// workstream replaces the internals while keeping this interface.
final class SwingAnalyzer {
    init() {}

    func analyze(_ request: AnalysisRequest,
                 progress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> AnalysisOutput {
        try await Task.detached(priority: .userInitiated) {
            progress(0.1, "Tracking ball")
            let fps = request.captureFPS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 240.0
            // TrackingEngine downsamples frames to half resolution before
            // measuring points, so keep ball size and metric scale in that
            // same coordinate space.
            let trackingPixelsPerMeter = request.calibration.map { $0.pixelsPerMeter / 2 }
            let trackingBallDiameter = request.calibration?.ballDiameterPx.map { $0 / 2 }
            let tracking = TrackingEngine().track(videoURL: request.clipURL, fps: fps,
                                                  expectedBallDiameterPx: trackingBallDiameter)
            var metrics: ShotMetrics?
            var failure: String?
            if request.calibration != nil, request.cameraView == .faceOn {
                do {
                    metrics = try MetricsCalculator.calculate(tracking: tracking,
                                                              pixelsPerMeter: trackingPixelsPerMeter ?? 0,
                                                              club: request.club)
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                failure = "Launch numbers need a face-on camera and a calibrated ball."
            }
            progress(0.9, "Rendering")
            let w = Double(max(tracking.frameWidth, 1)), h = Double(max(tracking.frameHeight, 1))
            var analysis = SwingAnalysis(fps: fps, frameWidth: tracking.frameWidth * 2, frameHeight: tracking.frameHeight * 2,
                                         duration: tracking.ballPoints.last?.time ?? 0,
                                         cameraView: request.cameraView, handedness: request.handedness,
                                         pixelsPerMeter: request.calibration?.pixelsPerMeter)
            analysis.ballTrack = tracking.ballPoints.map { TrackPoint(t: $0.time, x: $0.x / w, y: $0.y / h) }
            analysis.clubTrack = tracking.clubPoints.map { TrackPoint(t: $0.time, x: $0.x / w, y: $0.y / h) }
            if let i = tracking.impactBallIndex, i < tracking.ballPoints.count { analysis.impactTime = tracking.ballPoints[i].time }
            progress(0.6, "Reading body pose")
            let (poses, size, duration) = Self.interimPoses(videoURL: request.clipURL)
            analysis.poses = poses
            if size.width > 0 {
                analysis.frameWidth = Int(size.width)
                analysis.frameHeight = Int(size.height)
                analysis.duration = duration
            }
            analysis.phases = Self.interimPhases(poses, lead: request.handedness == .right ? .leftWrist : .rightWrist)
            if let top = analysis.marker(.top)?.t, let address = analysis.marker(.address)?.t,
               let impact = analysis.marker(.impact)?.t, top > address, impact > top {
                let back = top - address, down = impact - top
                analysis.metrics = [
                    SwingMetric(id: "tempo.ratio", name: "Tempo", value: back / down, unit: ":1",
                                tourRange: 2.7...3.3, rating: (2.7...3.3).contains(back / down) ? .tour : .good,
                                explanation: "Backswing time divided by downswing time."),
                    SwingMetric(id: "tempo.backswing", name: "Backswing", value: back, unit: "s", phase: .top),
                    SwingMetric(id: "tempo.downswing", name: "Downswing", value: down, unit: "s", phase: .impact),
                ]
            }
            let ballTracker = tracking.golfDetectorAssisted
                ? "GolfDetector-assisted v1 blob tracker"
                : "v1 blob tracker"
            analysis.pipeline = "\(ballTracker) + \(PoseEstimatorFactory.make()?.name ?? "no pose")"
            let tracer = TracerRenderer.makeTracerImage(videoURL: request.clipURL, tracking: tracking)
            let poster = Self.posterFrame(videoURL: request.clipURL, at: analysis.marker(.address)?.t ?? 0) ?? tracer
            progress(1, "Done")
            return AnalysisOutput(metrics: metrics, metricsError: failure, analysis: analysis,
                                  thumbnail: poster, tracerImage: tracer)
        }.value
    }

    // MARK: Interim helpers (replaced by the analysis workstream)

    /// Pose every 8th frame (≈30 fps at 240 fps capture).
    private static func interimPoses(videoURL: URL) -> ([PoseSample], CGSize, Double) {
        guard let estimator = PoseEstimatorFactory.make() else { return ([], .zero, 0) }
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return ([], .zero, 0) }
        var poses: [PoseSample] = []
        var size = CGSize.zero
        var t = 0.0
        while t < duration {
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                size = CGSize(width: cg.width, height: cg.height)
                if let p = estimator.pose(in: CIImage(cgImage: cg), t: t) { poses.append(p) }
            }
            t += 8.0 / 240.0
        }
        return (poses, size, duration)
    }

    /// Naive phases from the lead wrist: top = highest wrist, impact = lowest
    /// wrist after top, address = first sample, finish = last sample.
    private static func interimPhases(_ poses: [PoseSample], lead: BodyJoint) -> [SwingPhaseMarker] {
        let pts = poses.compactMap { p in p.point(lead).map { (p.t, $0) } }
        guard pts.count >= 6 else { return [] }
        // The lead wrist goes low (address) → high (top) → low (impact) →
        // high (finish). Impact = first return to address height after the
        // hands have risen; top = highest point before that.
        let addressY = pts.prefix(5).map(\.1.y).sorted()[min(2, pts.prefix(5).count - 1)]
        var minIndex = 0
        var topIndex: Int?
        for (i, p) in pts.enumerated() {
            if p.1.y < pts[minIndex].1.y { minIndex = i }
            let rise = addressY - pts[minIndex].1.y
            if rise > 0.08, p.1.y > pts[minIndex].1.y + 0.5 * rise { topIndex = minIndex; break }
        }
        guard let ti = topIndex else { return [] }
        let top = pts[ti]
        let window = pts[(ti + 1)...].prefix { $0.0 - top.0 <= 0.5 }
        guard let impact = window.max(by: { $0.1.y < $1.1.y }) else { return [] }
        let address = pts.first!.0
        let finish = pts.last!.0
        func mid(_ a: Double, _ b: Double) -> Double { a + (b - a) / 2 }
        return [
            SwingPhaseMarker(phase: .address, t: address, confidence: 0.3),
            SwingPhaseMarker(phase: .toeUp, t: address + (top.0 - address) * 0.35, confidence: 0.2),
            SwingPhaseMarker(phase: .midBackswing, t: address + (top.0 - address) * 0.65, confidence: 0.2),
            SwingPhaseMarker(phase: .top, t: top.0, confidence: 0.5),
            SwingPhaseMarker(phase: .midDownswing, t: mid(top.0, impact.0), confidence: 0.3),
            SwingPhaseMarker(phase: .impact, t: impact.0, confidence: 0.5),
            SwingPhaseMarker(phase: .midFollowThrough, t: mid(impact.0, finish), confidence: 0.2),
            SwingPhaseMarker(phase: .finish, t: finish, confidence: 0.3),
        ]
    }

    private static func posterFrame(videoURL: URL, at t: Double) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Finds the ball in a single preview frame for calibration ("Detect ball").
enum BallLocator {
    static func locate(in sampleBuffer: CMSampleBuffer) -> BallDetectionOutcome {
        TrackingEngine.detectBall(in: sampleBuffer)
    }
}

// MARK: - Shot factory

extension Shot {
    /// Builds a library Shot from an analysis result. Launch fields are 0
    /// when the analyzer couldn't measure them (see AnalysisOutput.metricsError).
    static func make(from output: AnalysisOutput, request: AnalysisRequest,
                     source: ShotSource = .live, date: Date = Date()) -> Shot {
        let m = output.metrics
        let a = output.analysis
        var shot = Shot(
            date: date,
            club: request.club,
            ballSpeedMph: m?.ballSpeedMph ?? 0,
            clubSpeedMph: m?.clubSpeedMph ?? 0,
            launchAngleDeg: m?.launchAngleDeg ?? 0,
            carryYards: m?.carryYards ?? 0,
            apexYards: m?.apexYards ?? 0,
            hangTimeS: m?.hangTimeS ?? 0,
            smashFactor: m?.smashFactor ?? 0,
            tempoRatio: a.metric("tempo.ratio")?.value ?? m?.tempoRatio ?? 0,
            offlineYards: m?.offlineYards ?? 0,
            cameraView: request.cameraView,
            source: source
        )
        shot.backswingTimeS = a.metric("tempo.backswing")?.value
        shot.downswingTimeS = a.metric("tempo.downswing")?.value
        shot.metricSummary = Dictionary(a.metrics.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        shot.impactTimeInClip = a.impactTime
        return shot
    }
}
