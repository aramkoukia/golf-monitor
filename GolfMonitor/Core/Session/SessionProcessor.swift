import Foundation
import UIKit

/// One finished recording, ready to be analyzed.
struct RecordedSession {
    var videoURL: URL
    var duration: Double
    var fps: Double
    /// What the live monitor saw. nil (or empty) → scanned from the file.
    var timeline: SceneTimeline?
}

/// User choices that shape processing.
struct SessionContext {
    var club: Club
    var cameraView: CameraView
    var handedness: Handedness
    var saveShotsToPhotos: Bool
    var saveSessionToPhotos: Bool
    var source: ShotSource = .live
    /// Stop was pressed on the phone itself, so the end of the recording is
    /// the golfer walking up to it (see `ShotFinder.analyze`).
    var stoppedAtPhone = false
}

struct ProcessingProgress: Equatable {
    enum Step: Int, CaseIterable, Comparable {
        case finding, measuring, analyzing, saving

        var title: String {
            switch self {
            case .finding: return "Finding your shot"
            case .measuring: return "Measuring ball flight"
            case .analyzing: return "Reading your swing"
            case .saving: return "Saving"
            }
        }

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var step: Step
    /// Overall 0...1.
    var fraction: Double
    var detail: String

    static let start = ProcessingProgress(step: .finding, fraction: 0, detail: "Finding your shot")
}

/// The shot shown on the reveal screen.
struct FeaturedShot {
    var shot: Shot
    var analysis: SwingAnalysis
    var tracerImage: UIImage? = nil
    var thumbnail: UIImage? = nil
    /// Why launch numbers are missing, if they are.
    var metricsError: String? = nil
}

struct SessionOutcome {
    /// Saved shots, in recording order.
    var shots: [Shot]
    var featured: FeaturedShot?
    var swingsSeen: Int
    var practiceSwings: Int
    var struckCount: Int
    var savedToPhotos: Bool
    /// Non-fatal problems ("couldn't save to Photos"…).
    var warnings: [String]
}

@MainActor
protocol SessionProcessing: AnyObject {
    func process(_ session: RecordedSession, context: SessionContext,
                 progress: @escaping @MainActor (ProcessingProgress) -> Void) async throws -> SessionOutcome
}

/// Recording → shots: finds the swings and the ball strike(s) on the
/// timeline, cuts each shot out of the recording, calibrates from the struck
/// ball's measured diameter, runs the on-device `SwingAnalyzer`, saves the
/// shot (clip + analysis + thumbnail) to the library and, if the user wants,
/// to Photos. The full recording is deleted afterwards.
@MainActor
final class SessionProcessor: SessionProcessing {
    private let store: ShotStore
    private let photos: PhotoLibrarySaving
    private let makeLocator: () -> BallLocating
    private let finder: ShotFinder
    var maxShotsPerSession = 6

    init(store: ShotStore, photos: PhotoLibrarySaving = PhotoLibrarySaver(),
         finder: ShotFinder = ShotFinder(), makeLocator: @escaping () -> BallLocating = { GolfBallLocator() }) {
        self.store = store
        self.photos = photos
        self.finder = finder
        self.makeLocator = makeLocator
    }

    func process(_ session: RecordedSession, context: SessionContext,
                 progress: @escaping @MainActor (ProcessingProgress) -> Void) async throws -> SessionOutcome {
        defer { try? FileManager.default.removeItem(at: session.videoURL) }
        progress(ProcessingProgress(step: .finding, fraction: 0.02, detail: "Finding your shot"))

        let timeline: SceneTimeline
        if let live = session.timeline, !live.motion.isEmpty {
            timeline = live
        } else {
            let locator = makeLocator()
            timeline = try await SceneScanner.scan(url: session.videoURL, locator: locator) { p in
                Task { @MainActor in
                    progress(ProcessingProgress(step: .finding, fraction: 0.02 + 0.18 * p, detail: "Scanning the recording"))
                }
            }
        }
        let found = finder.analyze(timeline, stoppedAtPhone: context.stoppedAtPhone)
        guard !found.shots.isEmpty else { throw SessionError.noMotionFound }

        var saved: [Shot] = []
        var featured: FeaturedShot?
        var warnings: [String] = []
        var savedToPhotos = false
        let shots = Array(found.shots.prefix(maxShotsPerSession))
        let span = 0.75 / Double(shots.count)

        for (index, candidate) in shots.enumerated() {
            let base = 0.2 + span * Double(index)
            let label = shots.count > 1 ? "Shot \(index + 1) of \(shots.count) · " : ""
            progress(ProcessingProgress(step: .measuring, fraction: base, detail: label + "Cutting the clip"))
            let clipURL = try await ClipExporter.export(from: session.videoURL,
                                                        start: candidate.clipStart, end: candidate.clipEnd)

            var request = AnalysisRequest(
                clipURL: clipURL, club: context.club, cameraView: context.cameraView,
                handedness: context.handedness,
                calibration: candidate.kind == .struck ? candidate.ball.map(Calibration.init(ball:)) : nil,
                captureFPS: session.fps)
            request.impactTimeHint = candidate.impactTime.map { $0 - candidate.clipStart }
            request.ballHint = candidate.ball?.center

            let output: AnalysisOutput
            do {
                output = try await SwingAnalyzer().analyze(request) { p, status in
                    Task { @MainActor in
                        let step: ProcessingProgress.Step = p < 0.5 ? .measuring : .analyzing
                        progress(ProcessingProgress(step: step, fraction: base + span * 0.9 * p, detail: label + status))
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: clipURL)
                warnings.append("\(label)analysis failed: \(error.localizedDescription)")
                continue
            }

            progress(ProcessingProgress(step: .saving, fraction: base + span * 0.95, detail: label + "Saving to your library"))
            let shot = Shot.make(from: output, request: request, source: context.source)
            let stored = store.addShot(shot, clipURL: clipURL, analysis: output.analysis, thumbnail: output.thumbnail)
            saved.append(stored)

            if candidate.kind == .struck || featured == nil {
                featured = FeaturedShot(shot: stored, analysis: output.analysis, tracerImage: output.tracerImage,
                                        thumbnail: output.thumbnail,
                                        metricsError: candidate.kind == .swingOnly
                                            ? "No ball strike was found, so this is a swing-only analysis."
                                            : output.metricsError)
            }

            if context.saveShotsToPhotos, let url = store.clipURL(for: stored.id) {
                do {
                    try await photos.saveVideo(at: url)
                    savedToPhotos = true
                } catch {
                    warnings.append(error.localizedDescription)
                }
            }
        }

        if context.saveSessionToPhotos {
            progress(ProcessingProgress(step: .saving, fraction: 0.97, detail: "Saving the full recording to Photos"))
            do {
                try await photos.saveVideo(at: session.videoURL)
                savedToPhotos = true
            } catch {
                warnings.append(error.localizedDescription)
            }
        }

        guard !saved.isEmpty else { throw SessionError.recordingFailed(warnings.first ?? "no shot could be analyzed") }
        progress(ProcessingProgress(step: .saving, fraction: 1, detail: "Done"))
        return SessionOutcome(shots: saved, featured: featured, swingsSeen: found.swings.count,
                              practiceSwings: found.practiceSwingCount, struckCount: found.struckCount,
                              savedToPhotos: savedToPhotos, warnings: Array(Set(warnings)).sorted())
    }
}

extension Calibration {
    /// Pixels-per-metre from a ball's measured diameter (42.67 mm ball).
    init(ball: BallTrack) {
        self.init()
        ballDiameterPx = ball.diameterPx
        pixelsPerMeter = ball.diameterPx / Calibration.golfBallDiameterMeters
        isCalibrated = true
    }
}
