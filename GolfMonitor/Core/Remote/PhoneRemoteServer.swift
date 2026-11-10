import Foundation
import Combine
import WatchConnectivity

/// Executes watch commands on the phone (the range session controller).
@MainActor
protocol RemoteCommandHandling: AnyObject {
    func handleRemote(_ request: RemoteRequest) -> RemoteReply
    func currentRemoteState() -> RemoteState
}

/// Watch connection status for the phone UI.
@MainActor
final class WatchLinkStatus: ObservableObject {
    @Published var isSupported = WCSession.isSupported()
    @Published var isPaired = false
    @Published var isAppInstalled = false
    @Published var isReachable = false

    var summary: String {
        if !isSupported || !isPaired { return "No Apple Watch paired" }
        if !isAppInstalled { return "Install GolfMonitor on your watch" }
        return isReachable ? "Watch connected" : "Open GolfMonitor on your watch"
    }
}

/// Remembers replies to recent requests so a retried request (same id)
/// isn't executed twice — e.g. a "start" whose reply was lost.
struct RemoteRequestLedger {
    var capacity = 32
    private var replies: [UUID: RemoteReply] = [:]
    private var order: [UUID] = []

    func reply(for id: UUID) -> RemoteReply? { replies[id] }

    mutating func record(_ reply: RemoteReply, for id: UUID) {
        if replies[id] == nil { order.append(id) }
        replies[id] = reply
        while order.count > capacity { replies[order.removeFirst()] = nil }
    }
}

/// Preview lease + reachability, read from the camera queue.
private final class PreviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lease = PreviewLease()
    private var reachable = false

    var isOpen: Bool { lock.withLock { reachable && lease.isActive() } }
    func renew() { lock.withLock { lease.renew() } }
    func revoke() { lock.withLock { lease.revoke() } }
    func setReachable(_ value: Bool) {
        lock.withLock {
            reachable = value
            if !value { lease.revoke() }
        }
    }
}

/// The phone end of the watch link (WatchConnectivity). Receives commands,
/// replies with the current state, pushes every state change, and streams
/// preview frames while the watch holds a lease.
@MainActor
final class PhoneRemoteServer: NSObject, WCSessionDelegate {
    static let shared = PhoneRemoteServer()

    nonisolated let streamer = WatchPreviewStreamer()
    let link = WatchLinkStatus()
    weak var handler: RemoteCommandHandling?

    nonisolated private let gate = PreviewGate()
    private var ledger = RemoteRequestLedger()
    private var lastSentAt = Date.distantPast
    private var pendingPublish = false

    override private init() {
        super.init()
        let gate = self.gate
        streamer.isActive = { gate.isOpen }
        streamer.send = { [weak self] data in self?.sendPreview(data) }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Publishing state

    /// Pushes the latest state to the watch (≤ 5 updates/s; the newest wins).
    func publish() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let wait = 0.2 - Date().timeIntervalSince(lastSentAt)
        if wait > 0 {
            guard !pendingPublish else { return }
            pendingPublish = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.pendingPublish = false
                self?.publish()
            }
            return
        }
        guard let state = handler?.currentRemoteState() else { return }
        lastSentAt = Date()
        let session = WCSession.default
        let message = RemoteWire.message(state, kind: .state)
        if session.isPaired, session.isWatchAppInstalled {
            try? session.updateApplicationContext(message)
        }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Preview

    nonisolated private func sendPreview(_ data: Data) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            streamer.delivered()
            return
        }
        session.sendMessageData(data, replyHandler: { [weak self] _ in
            self?.streamer.delivered()
        }, errorHandler: { [weak self] _ in
            self?.streamer.delivered()
        })
    }

    // MARK: Requests

    private func handle(_ request: RemoteRequest) -> RemoteReply {
        switch request.command {
        case .subscribePreview:
            gate.renew()
            return RemoteReply(accepted: true, reason: nil, state: handler?.currentRemoteState())
        case .unsubscribePreview:
            gate.revoke()
            return RemoteReply(accepted: true, reason: nil, state: handler?.currentRemoteState())
        case .requestState:
            return RemoteReply(accepted: true, reason: nil, state: handler?.currentRemoteState())
        default:
            break
        }
        if let previous = ledger.reply(for: request.id) { return previous }
        guard RemoteWire.isFresh(request) else {
            return RemoteReply(accepted: false, reason: "That command arrived too late — try again.",
                               state: handler?.currentRemoteState())
        }
        guard let handler else {
            return RemoteReply(accepted: false, reason: "Open GolfMonitor on your iPhone.", state: nil)
        }
        let reply = handler.handleRemote(request)
        ledger.record(reply, for: request.id)
        return reply
    }

    nonisolated private func receive(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        guard let request = RemoteWire.decode(RemoteRequest.self, from: message, kind: .request) else {
            reply?(RemoteWire.message(RemoteReply(accepted: false, reason: "Unknown message — update both apps.",
                                                  state: nil), kind: .reply))
            return
        }
        Task { @MainActor in
            let result = self.handle(request)
            reply?(RemoteWire.message(result, kind: .reply))
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        refreshLink(session)
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required when the user switches watches: re-activate for the new one.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        refreshLink(session)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        refreshLink(session)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message, reply: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message, reply: replyHandler)
    }

    nonisolated private func refreshLink(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let isReachable = session.activationState == .activated && session.isReachable
        gate.setReachable(isReachable)
        Task { @MainActor in
            self.link.isPaired = paired
            self.link.isAppInstalled = installed
            self.link.isReachable = isReachable
            self.publish()
        }
    }
}
