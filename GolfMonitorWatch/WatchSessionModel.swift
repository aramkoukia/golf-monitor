import Foundation
import Combine
import UIKit
import WatchConnectivity
import WatchKit

/// The watch end of the phone link: sends commands, keeps the latest phone
/// state, renews the preview lease while the preview is on screen, and plays
/// a haptic for every phase change so you can feel "recording" / "done"
/// without looking, plus a tap when a newly teed ball locks.
@MainActor
final class WatchSessionModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var state: RemoteState?
    @Published private(set) var stateReceivedAt: Date?
    @Published private(set) var isReachable = false
    @Published private(set) var preview: UIImage?
    @Published private(set) var previewReceivedAt: Date?
    @Published private(set) var pendingCommand: RemoteCommand?
    @Published private(set) var lastError: String?

    var screen: RemoteScreenModel { RemoteScreenModel.make(state: state, reachable: isReachable) }

    /// Local clock time the recording started (skew-free: derived from the
    /// phone's elapsed seconds when the state arrived).
    var recordingStartedAt: Date? {
        guard let state, state.phase == .recording, let elapsed = state.recordingElapsed,
              let received = stateReceivedAt else { return nil }
        return received.addingTimeInterval(-elapsed)
    }

    /// The preview is fresh enough to show.
    var hasLivePreview: Bool {
        guard preview != nil, let at = previewReceivedAt else { return false }
        return Date().timeIntervalSince(at) < 3
    }

    private var previewVisible = false
    private var isMocked = false
    /// An action tapped before WCSession finished activating.
    private var queuedAction: (RemoteCommand, String?)?
    private var leaseTask: Task<Void, Never>?
    private var lockCue = BallLockCue()

    func activate() {
        guard WCSession.isSupported() else {
            lastError = "WatchConnectivity unavailable"
            return
        }
        let session = WCSession.default
        session.delegate = self
        if session.activationState == .activated {
            refresh(session)
        } else {
            session.activate()
        }
    }

    // MARK: Commands

    func performPrimaryAction() {
        switch screen.primary {
        case .start: send(.start)
        case .stop: send(.stop)
        case .nextShot: send(.dismissResult)
        case .none: send(.requestState)
        }
    }

    func selectClub(_ rawValue: String) {
        send(.selectClub, argument: rawValue)
    }

    func send(_ command: RemoteCommand, argument: String? = nil) {
        let session = WCSession.default
        let isAction = ![.requestState, .subscribePreview, .unsubscribePreview].contains(command)
        guard session.activationState == .activated else {
            if isAction { queuedAction = (command, argument) }
            session.activate()
            return
        }
        let request = RemoteRequest(command: command, argument: argument)
        if isAction {
            pendingCommand = command
            lastError = nil
            WKInterfaceDevice.current().play(.click)
        }
        // `isReachable` can lag behind the real link, so always try and let
        // the delivery result decide (one retry for a link that's waking up).
        deliver(request, isAction: isAction, attemptsLeft: isAction ? 1 : 0)
    }

    private func deliver(_ request: RemoteRequest, isAction: Bool, attemptsLeft: Int) {
        let command = request.command
        WCSession.default.sendMessage(RemoteWire.message(request, kind: .request), replyHandler: { [weak self] reply in
            let decoded = RemoteWire.decode(RemoteReply.self, from: reply, kind: .reply)
            Task { @MainActor in
                self?.isReachable = true
                self?.handleReply(decoded, for: command, isAction: isAction)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if attemptsLeft > 0 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self.deliver(request, isAction: isAction, attemptsLeft: attemptsLeft - 1)
                    return
                }
                if isAction {
                    self.pendingCommand = nil
                    self.lastError = "iPhone not reachable — open GolfMonitor on it"
                    WKInterfaceDevice.current().play(.failure)
                }
            }
        })
    }

    private func handleReply(_ reply: RemoteReply?, for command: RemoteCommand, isAction: Bool) {
        if isAction { pendingCommand = nil }
        guard let reply else { return }
        if let state = reply.state { apply(state) }
        if isAction, !reply.accepted {
            lastError = reply.reason ?? "The iPhone couldn't do that"
            WKInterfaceDevice.current().play(.failure)
        }
    }

    // MARK: Preview lease

    /// Call when the preview appears / disappears or the app (de)activates.
    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        leaseTask?.cancel()
        guard visible else {
            send(.unsubscribePreview)
            return
        }
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.screen.wantsPreview { self.send(.subscribePreview) }
                try? await Task.sleep(nanoseconds: UInt64(RemoteWire.previewRenewInterval * 1_000_000_000))
            }
        }
    }

    // MARK: State

    private func apply(_ incoming: RemoteState) {
        guard incoming.supersedes(state) else { return }
        let previousState = state
        let previous = state?.phase
        state = incoming
        stateReceivedAt = Date()
        let phaseChanged = previous != nil && previous != incoming.phase
        if let previous, phaseChanged { playHaptic(from: previous, to: incoming.phase) }
        if lockCue.shouldTap(previous: previousState, incoming: incoming) {
            // Let a phase haptic (e.g. "recording") finish first so both are felt.
            Task { @MainActor in
                if phaseChanged { try? await Task.sleep(nanoseconds: 700_000_000) }
                WKInterfaceDevice.current().play(.notification)
            }
        }
        if incoming.phase != .ready && incoming.phase != .recording { preview = nil }
    }

    private func playHaptic(from old: RemotePhase, to new: RemotePhase) {
        let device = WKInterfaceDevice.current()
        switch new {
        case .recording: device.play(.start)
        case .processing: device.play(.stop)
        case .result: device.play(.success)
        case .error: device.play(.failure)
        case .ready where old == .notReady: device.play(.directionUp)
        default: break
        }
    }

    private func refresh(_ session: WCSession) {
        guard !isMocked else { return }
        isReachable = session.activationState == .activated && session.isReachable
        if let cached = RemoteWire.decode(RemoteState.self, from: session.receivedApplicationContext, kind: .state) {
            apply(cached)
        }
        if let queued = queuedAction, session.activationState == .activated {
            queuedAction = nil
            send(queued.0, argument: queued.1)
        }
        if isReachable {
            send(.requestState)
            if previewVisible { send(.subscribePreview) }
        }
    }

    #if DEBUG
    /// `-gm.mockState <phase>`: show a canned phone state (screenshots without a paired iPhone).
    func applyMockState(_ phase: RemotePhase) {
        var mock = RemoteState.placeholder()
        mock.phase = phase
        mock.revision = (state?.revision ?? 0) + 1
        mock.fps = 240
        mock.ballLocked = true
        mock.club = "7 Iron"
        mock.clubShort = "7i"
        switch phase {
        case .recording:
            mock.recordingElapsed = 12
            mock.swingsDetected = 2
        case .processing:
            mock.progress = 0.62
            mock.message = "Reading your swing"
        case .result:
            mock.lastShot = RemoteShotSummary(club: "7 Iron", clubShort: "7i", hasLaunchData: true, carry: 162,
                                              ballSpeed: 118, clubSpeed: 87, launchAngle: 17.2, smash: nil, tempo: 3.1,
                                              distanceUnit: "YDS", speedUnit: "MPH", practiceSwings: 2, shotsFound: 1,
                                              headline: "162 yds carry", savedToPhotos: true)
        case .error:
            mock.message = "No swing was found in the recording."
        case .notReady:
            mock.message = "Camera starting…"
        case .ready:
            break
        }
        isMocked = true
        isReachable = true
        state = mock
        stateReceivedAt = Date()
        if phase == .ready || phase == .recording {
            preview = UIImage(named: "MockPreview")
            previewReceivedAt = .distantFuture
        }
    }
    #endif

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.refresh(session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh(session) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = RemoteWire.decode(RemoteState.self, from: applicationContext, kind: .state)
        Task { @MainActor in if let state { self.apply(state) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let state = RemoteWire.decode(RemoteState.self, from: message, kind: .state)
        Task { @MainActor in if let state { self.apply(state) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let state = RemoteWire.decode(RemoteState.self, from: message, kind: .state)
        replyHandler([:])
        Task { @MainActor in if let state { self.apply(state) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        replyHandler(Data())
        let image = UIImage(data: messageData)
        Task { @MainActor in
            guard let image, self.screen.wantsPreview else { return }
            self.preview = image
            self.previewReceivedAt = Date()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        let image = UIImage(data: messageData)
        Task { @MainActor in
            guard let image else { return }
            self.preview = image
            self.previewReceivedAt = Date()
        }
    }
}
