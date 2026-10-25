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
            let fps = 240.0
            let tracking = TrackingEngine().track(videoURL: request.clipURL, fps: fps,
                                                  expectedBallDiameterPx: request.calibration?.ballDiameterPx)
            var metrics: ShotMetrics?
            var failure: String?
            if let cal = request.calibration, request.cameraView == .faceOn {
                do {
                    metrics = try MetricsCalculator.calculate(tracking: tracking, pixelsPerMeter: cal.pixelsPerMeter, club: request.club)
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
            analysis.pipeline = "v1 blob tracker"
            let tracer = TracerRenderer.makeTracerImage(videoURL: request.clipURL, tracking: tracking)
            progress(1, "Done")
            return AnalysisOutput(metrics: metrics, metricsError: failure, analysis: analysis,
                                  thumbnail: tracer, tracerImage: tracer)
        }.value
    }
}

/// Finds the ball in a single preview frame for calibration ("Detect ball").
enum BallLocator {
    static func locate(in sampleBuffer: CMSampleBuffer) -> BallDetectionOutcome {
        TrackingEngine.detectBall(in: sampleBuffer)
    }
}
