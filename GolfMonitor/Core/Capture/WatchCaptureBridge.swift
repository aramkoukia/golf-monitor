import Combine
import Foundation
import WatchConnectivity

final class WatchCaptureBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchCaptureBridge()

    @Published private(set) var isPaired = false
    @Published private(set) var isReachable = false
    @Published private(set) var isRecording = false
    @Published private(set) var canStartCapture = false
    var commandHandler: ((String) -> (accepted: Bool, reason: String?))?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshState()
    }

    func updateCaptureState(isRecording recording: Bool, canStart: Bool) {
        DispatchQueue.main.async {
            self.isRecording = recording
            self.canStartCapture = canStart
            self.updateApplicationContext()
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.refreshState()
            self.updateApplicationContext()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshState()
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = message["command"] as? String,
              command == "start" || command == "stop" else {
            replyHandler(["accepted": false, "reason": "Unknown command"])
            return
        }
        DispatchQueue.main.async {
            let response = self.commandHandler?(command)
                ?? (false, "Open GolfMonitor on the iPhone Range screen.")
            replyHandler([
                "accepted": response.accepted,
                "reason": response.reason ?? ""
            ])
        }
    }

    private func refreshState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        isPaired = session.isPaired && session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func updateApplicationContext() {
        guard WCSession.isSupported() else { return }
        do {
            try WCSession.default.updateApplicationContext([
                "recording": isRecording,
                "canStart": canStartCapture,
                "phoneReachable": WCSession.default.isReachable,
                "watchPaired": WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
            ])
        } catch {
            NSLog("Could not update Watch capture state: %@", error.localizedDescription)
        }
    }
}
