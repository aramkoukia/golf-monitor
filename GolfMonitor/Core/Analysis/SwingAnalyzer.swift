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
    /// Actual capture rate. Nil keeps the analyzer's 240 fps default.
    var captureFPS: Double? = nil
    /// Seconds from clip start where the ball left (from the scene monitor).
    var impactTimeHint: Double? = nil
    /// Where the ball sat at address, in upright frame pixels.
    var ballHint: CGPoint? = nil
}

struct AnalysisOutput {
    /// Launch numbers, nil when not measurable (down-the-line, ball lost…).
    var metrics: ShotMetrics?
    /// Why launch numbers are missing, user-presentable.
    var metricsError: String?
    var analysis: SwingAnalysis
    /// 0–1 confidence in the ball track behind the launch numbers.
    var trackingQuality: Double?
    /// Poster frame (address position) for lists.
    var thumbnail: UIImage?
    /// Impact frame with the measured ball path drawn on it.
    var tracerImage: UIImage?
}

/// Offline, on-device analysis of one shot clip:
///  • ball launch (speed, angle) from the frames after impact → flight model
///    for carry / apex / hang time / descent (`LaunchMeasurer`, `FlightModel`)
///  • body pose (Apple Vision on device; YOLO11n-pose Core ML in the Simulator)
///  • swing phases and tempo anchored on the impact time (`SwingPhaseDetector`)
final class SwingAnalyzer {
    init() {}

    func analyze(_ request: AnalysisRequest,
                 progress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> AnalysisOutput {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: request.clipURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LaunchError.unreadableClip
            }
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            let fps = request.captureFPS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 240
            var analysis = SwingAnalysis(fps: fps, frameWidth: Int(size.width), frameHeight: Int(size.height),
                                         duration: duration, cameraView: request.cameraView,
                                         handedness: request.handedness,
                                         pixelsPerMeter: request.calibration?.pixelsPerMeter)

            // 1. Ball launch.
            progress(0.05, "Measuring ball flight")
            var metrics: ShotMetrics?
            var failure: String?
            var quality: Double?
            if let ball = request.ballHint {
                analysis.ballAddress = TrackPoint(t: 0, x: Double(ball.x) / max(1, Double(analysis.frameWidth)),
                                                  y: Double(ball.y) / max(1, Double(analysis.frameHeight)))
            }
            if request.cameraView == .downTheLine {
                failure = "Down-the-line view analyzes the swing; switch to face-on for ball speed and carry."
            } else if let calibration = request.calibration, calibration.isCalibrated,
                      let diameter = calibration.ballDiameterPx, let ball = request.ballHint,
                      let impact = request.impactTimeHint {
                do {
                    let launch = try await LaunchMeasurer.measure(videoURL: request.clipURL, impactTimeHint: impact,
                                                                  ballCenter: ball, ballDiameterPx: diameter,
                                                                  pixelsPerMeter: calibration.pixelsPerMeter)
                    let (m, flight) = FlightModel.metrics(ballSpeedMps: launch.speedMps,
                                                          launchAngleDeg: launch.launchAngleDeg, club: request.club)
                    metrics = m
                    quality = launch.quality
                    analysis.impactTime = launch.impactTime
                    analysis.ballTrack = launch.points
                    analysis.flight = flight.samples
                } catch {
                    failure = error.localizedDescription
                    analysis.impactTime = impact
                }
            } else {
                failure = "No ball strike was found, so this is a swing-only analysis."
                analysis.impactTime = request.impactTimeHint
            }

            // 2. Body pose and swing phases.
            progress(0.4, "Reading your swing")
            let estimator = PoseEstimatorFactory.make()
            if let estimator {
                let window: ClosedRange<Double> = analysis.impactTime.map { max(0, $0 - 2.0)...min(duration, $0 + 1.0) }
                    ?? 0...duration
                analysis.poses = try await Self.poses(in: asset, track: track, window: window, estimator: estimator) { p in
                    progress(0.4 + 0.5 * p, "Reading your swing")
                }
            }
            analysis.phases = SwingPhaseDetector.phases(from: analysis.poses, handedness: request.handedness,
                                                        impactTime: analysis.impactTime)
            if analysis.impactTime == nil { analysis.impactTime = analysis.marker(.impact)?.t }
            analysis.metrics = SwingPhaseDetector.tempoMetrics(from: analysis.phases)
                + PoseMetrics.metrics(from: analysis.poses)
            if var m = metrics {
                m.tempoRatio = analysis.metric("tempo.ratio")?.value ?? 0
                metrics = m
            }
            analysis.pipeline = [metrics != nil ? "GolfDetector + launch fit" : nil, estimator?.name]
                .compactMap { $0 }.joined(separator: " · ")

            // 3. Images.
            progress(0.93, "Rendering")
            let tracer = await TracerRenderer.render(videoURL: request.clipURL, analysis: analysis)
            let posterTime = analysis.marker(.address)?.t ?? max(0, (analysis.impactTime ?? 0.5) - 1.2)
            let poster = await Self.posterFrame(asset: asset, at: posterTime) ?? tracer
            progress(1, "Done")
            return AnalysisOutput(metrics: metrics, metricsError: metrics == nil ? failure : nil,
                                  analysis: analysis, trackingQuality: quality,
                                  thumbnail: poster, tracerImage: tracer)
        }.value
    }

    /// Poses at ~30 Hz across `window`, decoded sequentially (much faster
    /// than seeking frame by frame).
    private static func poses(in asset: AVURLAsset, track: AVAssetTrack, window: ClosedRange<Double>,
                              estimator: PoseEstimating, progress: (Double) -> Void) async throws -> [PoseSample] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: window.lowerBound, preferredTimescale: 6000),
                                       end: CMTime(seconds: window.upperBound, preferredTimescale: 6000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var poses: [PoseSample] = []
        var next = -Double.infinity
        let span = max(window.upperBound - window.lowerBound, 0.01)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t.isFinite, t >= next - 0.001, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = t + 1.0 / 30
            if let pose = estimator.pose(in: CIImage(cvPixelBuffer: buffer), t: t) { poses.append(pose) }
            progress(min(1, (t - window.lowerBound) / span))
        }
        return poses
    }

    private static func posterFrame(asset: AVURLAsset, at t: Double) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        guard let cg = await gen.frameImage(at: CMTime(seconds: t, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension AVAssetImageGenerator {
    func frameImage(at time: CMTime) async -> CGImage? {
        try? await image(at: time).image
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
        shot.descentAngleDeg = m?.descentAngleDeg
        shot.trackingQuality = output.trackingQuality
        shot.backswingTimeS = a.metric("tempo.backswing")?.value
        shot.downswingTimeS = a.metric("tempo.downswing")?.value
        shot.metricSummary = Dictionary(a.metrics.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        shot.impactTimeInClip = a.impactTime
        return shot
    }
}
