import SwiftUI
import Combine
import WatchConnectivity

@MainActor
final class WatchRemoteModel: NSObject, ObservableObject, @preconcurrency WCSessionDelegate {
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var isRecording = false
    @Published private(set) var canStartCapture = false
    @Published private(set) var status = "Connecting…"

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            status = "Watch unavailable"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendCaptureCommand() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            status = "Open GolfMonitor on iPhone"
            return
        }

        let command = isRecording ? "stop" : "start"
        status = command == "start" ? "Starting session…" : "Stopping session…"
        WCSession.default.sendMessage(
            ["command": command],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    if reply["accepted"] as? Bool == false {
                        self?.status = reply["reason"] as? String ?? "Phone could not start"
                    }
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in self?.status = "Keep GolfMonitor open on iPhone" }
            }
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            receiveCaptureState(session.receivedApplicationContext)
            updateConnection(session)
            if let error {
                status = "Connection issue"
                NSLog("Could not activate Watch capture session: %@", error.localizedDescription)
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in updateConnection(session) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            receiveCaptureState(applicationContext)
            updateConnection(session)
        }
    }

    private func receiveCaptureState(_ context: [String: Any]) {
        isRecording = context["recording"] as? Bool ?? false
        canStartCapture = context["canStart"] as? Bool ?? false
    }

    private func updateConnection(_ session: WCSession) {
        isPhoneReachable = session.activationState == .activated && session.isReachable
        if isRecording {
            status = "Session recording"
        } else if isPhoneReachable {
            status = canStartCapture ? "Ready to record" : "Open Range on iPhone"
        } else {
            status = "Open GolfMonitor on iPhone"
        }
    }
}

struct WatchRemoteView: View {
    @StateObject private var model = WatchRemoteModel()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isPhoneReachable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.status.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)

            Button(action: model.sendCaptureCommand) {
                VStack(spacing: 5) {
                    Image(systemName: model.isRecording ? "stop.fill" : "record.circle.fill")
                        .font(.system(size: 31, weight: .semibold))
                    Text(model.isRecording ? "END SESSION" : "START SESSION")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.isRecording ? Color.red : Color.orange, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isPhoneReachable || (!model.isRecording && !model.canStartCapture))
            .opacity(model.isPhoneReachable && (model.isRecording || model.canStartCapture) ? 1 : 0.5)
            .accessibilityLabel(model.isRecording ? "End range session" : "Start range session")
        }
        .padding(.horizontal, 8)
    }
}
