import Foundation
import Combine
import QuartzCore
import UIKit

/// The range session state machine, shared by the phone UI and the watch.
///
///     idle ──start──▶ recording ──stop / time limit──▶ processing ──▶ review
///       ▲                 │ cancel                         │ error       │
///       └─────────────────┴────────────── failed ◀─────────┘   dismiss ──┘
///
/// One recording covers the whole routine: set up, take practice swings, hit
/// the real shot, stop. Processing finds the strike (see `ShotFinder`),
/// measures it and saves it. Commands from the watch go through exactly the
/// same `start` / `stop` as the phone's buttons.
@MainActor
final class RangeSessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing
        case review
        case failed(String)

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
    }

    enum Origin: String { case phone, watch, system }

    struct LiveCounts: Equatable {
        var swings = 0
        var shots = 0
    }

    struct CommandResult: Equatable {
        var accepted: Bool
        var reason: String?

        static let ok = CommandResult(accepted: true, reason: nil)
        static func rejected(_ reason: String) -> CommandResult { CommandResult(accepted: false, reason: reason) }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: ProcessingProgress = .start
    @Published private(set) var outcome: SessionOutcome?
    @Published private(set) var feedback: RangeFeedback?
    @Published private(set) var live = LiveCounts()
    @Published private(set) var scene: SceneSnapshot = .empty
    /// Whether a recording started now is likely to be caught and measured.
    @Published private(set) var readiness: RemoteReadiness = .noBall
    @Published private(set) var isAppActive = true
    /// Bumped whenever the camera's readiness may have changed (for the UI).
    @Published private(set) var lastRejection: String?

    @Published var club: Club {
        didSet {
            guard club != oldValue else { return }
            defaults.set(club.rawValue, forKey: Self.clubKey)
            changed()
        }
    }

    let camera: RecordingDevice
    let monitor: SceneMonitor
    private let processor: SessionProcessing
    private let settings: SettingsStore
    private let store: ShotStore
    private let defaults: UserDefaults
    weak var router: AppRouter?
    /// Called after every state change (the watch link publishes from here).
    var onChange: (() -> Void)?
    var announcer: ShotAnnouncing?
    /// Keeps processing alive briefly if the phone is locked mid-analysis.
    var beginBackgroundWork: () -> (() -> Void) = RangeSessionController.uiKitBackgroundWork
    var cameraUnavailableReason: () -> String? = { nil }
    var now: () -> Date = Date.init
    var hostTime: () -> Double = CACurrentMediaTime
    /// Overrides the settings' recording limit (tests).
    var recordingLimitOverride: TimeInterval?

    /// Every ball the monitor has locked (a ball counts once, however often
    /// it is hidden and seen again). The watch taps when the count goes up.
    private var seenLockIDs = Set<UUID>()
    private let readinessCheck = RecordingReadiness()
    private(set) var ballLocksSeen = 0
    private var recordingHostStart: Double = 0
    private var limitTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private let epoch = UUID()
    private(set) var revision = 0

    static let clubKey = "golfmonitor.lastClub"

    init(camera: RecordingDevice, monitor: SceneMonitor, processor: SessionProcessing,
         settings: SettingsStore, store: ShotStore, defaults: UserDefaults = .standard) {
        self.camera = camera
        self.monitor = monitor
        self.processor = processor
        self.settings = settings
        self.store = store
        self.defaults = defaults
        club = defaults.string(forKey: Self.clubKey).flatMap(Club.init(rawValue:)) ?? .driver
    }

    // MARK: Commands

    @discardableResult
    func start(origin: Origin) -> CommandResult {
        switch phase {
        case .recording: return reject("Already recording.")
        case .processing: return reject("Still analyzing the last recording.")
        case .review, .failed: dismissResult()
        case .idle: break
        }
        guard isAppActive else {
            return reject("Open GolfMonitor on your iPhone — the camera only runs while the app is open.")
        }
        guard camera.isReadyToRecord else { return reject(cameraUnavailableReason() ?? "The camera isn't ready yet.") }
        do {
            try camera.startRecording()
        } catch {
            return reject(error.localizedDescription)
        }
        if store.activeSessionID == nil {
            store.startSession(cameraView: settings.cameraView, gameID: router?.rangeContext.gameID,
                               title: router?.rangeContext.title ?? "")
        }
        recordingHostStart = hostTime()
        live = LiveCounts()
        lastRejection = nil
        phase = .recording(startedAt: now())
        if origin == .watch { router?.tab = .range }
        scheduleTimeLimit()
        startLiveCounting()
        changed()
        return .ok
    }

    @discardableResult
    func stop(origin: Origin) -> CommandResult {
        guard phase.isRecording else { return reject("Nothing is recording.") }
        limitTask?.cancel()
        liveTask?.cancel()
        progress = .start
        phase = .processing
        changed()
        // Stopped with the phone's button, or by leaving the app: either way
        // the golfer walked up to the phone at the end of the recording.
        let context = SessionContext(club: club, cameraView: settings.cameraView, handedness: settings.handedness,
                                     saveShotsToPhotos: settings.saveShotsToPhotos,
                                     saveSessionToPhotos: settings.saveSessionToPhotos,
                                     stoppedAtPhone: origin == .phone || !isAppActive)
        processingTask = Task { [weak self] in await self?.finishRecording(context) }
        return .ok
    }

    /// Aborts a recording (nothing is saved) or an analysis in progress.
    @discardableResult
    func cancel() -> CommandResult {
        switch phase {
        case .recording:
            limitTask?.cancel()
            liveTask?.cancel()
            camera.cancelRecording()
        case .processing:
            processingTask?.cancel()
        default:
            return reject("Nothing to cancel.")
        }
        phase = .idle
        changed()
        return .ok
    }

    /// Leaves the result (or error) and gets ready for the next shot.
    func dismissResult() {
        guard phase == .review || { if case .failed = phase { return true } else { return false } }() else { return }
        outcome = nil
        feedback = nil
        phase = .idle
        changed()
    }

    // MARK: Inputs from the app

    func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        // The camera stops in the background: keep what was recorded.
        if !active, phase.isRecording { stop(origin: .system) }
        changed()
    }

    func updateScene(_ snapshot: SceneSnapshot) {
        let lockChanged = snapshot.isBallLocked != scene.isBallLocked
        let newLocks = snapshot.locks.filter { $0.isPresent && !seenLockIDs.contains($0.id) }
        seenLockIDs.formUnion(newLocks.map(\.id))
        ballLocksSeen += newLocks.count
        scene = snapshot
        let readinessChanged = refreshReadiness()
        if lockChanged || !newLocks.isEmpty || readinessChanged { changed() }
    }

    /// Re-checks readiness (scene or settings changed). True if it changed.
    @discardableResult
    func refreshReadiness() -> Bool {
        let next = readinessCheck.evaluate(
            RecordingReadiness.Inputs(scene: scene, cameraView: settings.cameraView, handedness: settings.handedness,
                                      fixedShutter: settings.shutterMode.seconds != nil),
            previous: readiness)
        guard next != readiness else { return false }
        readiness = next
        return true
    }

    /// The camera became (un)available.
    func cameraDidChange() { changed() }

    func handleCriticalPressure() {
        if phase.isRecording { stop(origin: .system) }
    }

    // MARK: Processing

    private func finishRecording(_ context: SessionContext) async {
        let endBackgroundWork = beginBackgroundWork()
        defer { endBackgroundWork() }
        do {
            let video = try await camera.stopRecording()
            let timeline = video.hasLiveTimeline ? monitor.timeline(from: video.startTime, to: video.endTime) : nil
            let session = RecordedSession(videoURL: video.url, duration: video.duration, fps: video.fps, timeline: timeline)
            let result = try await processor.process(session, context: context) { [weak self] p in
                guard let self, self.phase == .processing else { return }
                self.progress = p
                self.changed()
            }
            guard phase == .processing else { return }
            feedback = applyPracticeScoring(to: result.shots)
            outcome = result
            phase = .review
            announce(result)
        } catch is CancellationError {
            if phase == .processing { phase = .idle }
        } catch {
            if phase == .processing { phase = .failed(error.localizedDescription) }
        }
        changed()
    }

    private func applyPracticeScoring(to shots: [Shot]) -> RangeFeedback? {
        guard let context = router?.rangeContext, !context.isFree else { return nil }
        var last: RangeFeedback?
        for shot in shots where shot.hasLaunchData {
            guard var stored = store.shot(id: shot.id) else { continue }
            if let target = context.currentTarget() {
                stored.practice = PracticeContext(gameID: context.gameID ?? "practice", targetCarryYards: target.carryYards)
            }
            if let feedback = context.onShot(stored) {
                stored.practice?.points = feedback.points
                last = feedback
            }
            store.update(stored)
        }
        return last
    }

    private func announce(_ outcome: SessionOutcome) {
        guard settings.voiceReadout, let announcer else { return }
        if let feedback, let spoken = feedback.spoken {
            announcer.announce(spoken)
        } else if let text = ShotAnnouncer.sentence(for: outcome, settings: settings) {
            announcer.announce(text)
        }
    }

    // MARK: Timers

    private func scheduleTimeLimit() {
        limitTask?.cancel()
        let limit = recordingLimitOverride ?? settings.maxRecordingSeconds
        limitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(origin: .system)
        }
    }

    /// Live swing / shot counters while recording (what the watch shows).
    private func startLiveCounting() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            let finder = ShotFinder()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.phase.isRecording else { return }
                let timeline = self.monitor.timeline(from: self.recordingHostStart, to: self.hostTime())
                let result = finder.analyze(timeline, isFinal: false)
                let counts = LiveCounts(swings: result.swings.count, shots: result.struckCount)
                if counts != self.live {
                    self.live = counts
                    self.changed()
                }
            }
        }
    }

    // MARK: Helpers

    private func reject(_ reason: String) -> CommandResult {
        lastRejection = reason
        return .rejected(reason)
    }

    private func changed() {
        revision += 1
        onChange?()
    }

    private static func uiKitBackgroundWork() -> (() -> Void) {
        let app = UIApplication.shared
        var id = UIBackgroundTaskIdentifier.invalid
        id = app.beginBackgroundTask(withName: "Analyze shot") {
            app.endBackgroundTask(id)
            id = .invalid
        }
        return {
            guard id != .invalid else { return }
            app.endBackgroundTask(id)
            id = .invalid
        }
    }
}

// MARK: - Watch remote

extension RangeSessionController: RemoteCommandHandling {
    func handleRemote(_ request: RemoteRequest) -> RemoteReply {
        let result: CommandResult
        switch request.command {
        case .start: result = start(origin: .watch)
        case .stop: result = stop(origin: .watch)
        case .cancel: result = cancel()
        case .dismissResult:
            dismissResult()
            result = .ok
        case .selectClub:
            if let raw = request.argument, let selected = Club(rawValue: raw) {
                club = selected
                result = .ok
            } else {
                result = .rejected("Unknown club.")
            }
        case .requestState, .subscribePreview, .unsubscribePreview:
            result = .ok
        }
        return RemoteReply(accepted: result.accepted, reason: result.reason, state: currentRemoteState())
    }

    func currentRemoteState() -> RemoteState {
        var state = RemoteState.placeholder(epoch: epoch)
        state.club = club.rawValue
        state.clubShort = club.shortName
        state.maxRecordingSeconds = settings.maxRecordingSeconds
        state.ballLocked = scene.isBallLocked
        state.ballLocksSeen = ballLocksSeen
        state.readiness = readiness
        state.swingsDetected = live.swings
        state.shotsDetected = live.shots
        state.fps = Int(camera.frameRate.rounded())
        state.revision = revision
        state.sentAt = now()
        state.lastShot = outcome.map { RemoteSummaryBuilder.summary(for: $0, club: club, settings: settings) }

        switch phase {
        case .recording(let startedAt):
            state.phase = .recording
            state.recordingElapsed = max(0, now().timeIntervalSince(startedAt))
            state.message = "Recording"
        case .processing:
            state.phase = .processing
            state.progress = progress.fraction
            state.message = progress.detail
        case .review:
            state.phase = .result
            state.message = state.lastShot?.headline ?? "Done"
        case .failed(let reason):
            state.phase = .error
            state.message = reason
        case .idle:
            if !isAppActive {
                state.phase = .notReady
                state.message = "Open GolfMonitor on your iPhone"
            } else if !camera.isReadyToRecord {
                state.phase = .notReady
                state.message = cameraUnavailableReason() ?? "Camera starting…"
            } else {
                state.phase = .ready
                state.message = scene.isBallLocked ? "Ball locked" : "Ready"
            }
        }
        return state
    }
}

/// Converts an outcome to the watch's summary, in display units.
enum RemoteSummaryBuilder {
    static func summary(for outcome: SessionOutcome, club: Club, settings: SettingsStore) -> RemoteShotSummary {
        let shot = outcome.featured?.shot
        let measured = shot?.hasLaunchData == true
        func speed(_ mph: Double?) -> Double? { mph.flatMap { $0 > 0 ? settings.speedValue(mph: $0) : nil } }
        let carry = measured ? shot.map { settings.distanceValue(yards: $0.carryYards) } : nil
        let headline: String
        if measured, let carry {
            headline = "\(Int(carry.rounded())) \(settings.distanceUnitLabel) carry"
        } else if outcome.struckCount > 0 {
            headline = "Strike found — ball flight unclear"
        } else {
            headline = "No ball strike found · swing saved"
        }
        return RemoteShotSummary(
            club: (shot?.club ?? club).rawValue, clubShort: (shot?.club ?? club).shortName,
            hasLaunchData: measured, carry: carry,
            ballSpeed: measured ? speed(shot?.ballSpeedMph) : nil,
            clubSpeed: measured ? speed(shot?.clubSpeedMph) : nil,
            launchAngle: measured ? shot?.launchAngleDeg : nil,
            smash: measured ? shot.flatMap { $0.smashFactor > 0 ? $0.smashFactor : nil } : nil,
            tempo: shot.flatMap { $0.tempoRatio > 0 ? $0.tempoRatio : nil },
            distanceUnit: settings.distanceUnitLabel.uppercased(),
            speedUnit: settings.speedUnitLabel.uppercased(),
            practiceSwings: outcome.practiceSwings, shotsFound: outcome.struckCount,
            headline: headline, savedToPhotos: outcome.savedToPhotos)
    }
}
