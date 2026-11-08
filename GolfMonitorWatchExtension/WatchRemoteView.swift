import SwiftUI
import Combine
import UIKit
import WatchConnectivity
import WatchKit

@MainActor
final class WatchRemoteModel: NSObject, ObservableObject, @preconcurrency WCSessionDelegate {
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var isRecording = false
    @Published private(set) var canStartCapture = false
    @Published private(set) var previewImage: Image?
    @Published private(set) var status = "Connecting…"
    @Published private(set) var phoneDiagnostic = ""
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
        let command = isRecording ? "stop" : "start"
        sendCommand(command)
    }

    func openPhoneCamera() {
        if let url = URL(string: "golfmonitor://open-range") {
            WKExtension.shared().openSystemURL(url)
        }
        sendCommand("open_camera")
    }

    private func sendCommand(_ command: String) {
        let requestID = UUID().uuidString
        let session = WCSession.default

        guard session.activationState == .activated else {
            session.activate()
            session.transferUserInfo(["command": command, "requestID": requestID])
            status = "Command queued — activating Watch link"
            return
        }

        // Deliver durably even when live messaging is available. The phone retries
        // temporary Range/readiness failures and caches successful request IDs.
        session.transferUserInfo(["command": command, "requestID": requestID])

        guard session.isReachable else {
            status = command == "open_camera" ? "Opening phone camera…" :
                (command == "start" ? "Start queued — keep Range open" : "Stop queued — keep Range open")
            return
        }

        status = command == "open_camera" ? "Opening phone camera…" :
            (command == "start" ? "Starting swing…" : "Ending swing…")
        session.sendMessage(
            ["command": command, "requestID": requestID],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self else { return }
                    if reply["accepted"] as? Bool == true {
                        if command == "open_camera" {
                            self.status = "Opening iPhone Range"
                            self.requestCurrentState(session)
                        } else {
                            self.isRecording = command == "start"
                            self.status = command == "start" ? "Swing armed — swing now" : "Ready for swing"
                        }
                    } else {
                        self.status = reply["reason"] as? String ?? "Phone could not complete the command"
                    }
                }
            },
            errorHandler: { [weak self] error in
                session.transferUserInfo(["command": command, "requestID": requestID])
                Task { @MainActor in
                    self?.status = "Command queued — keep Range open"
                    NSLog("Watch command message failed: %@", error.localizedDescription)
                }
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
            requestCurrentState(session)
            if let error {
                status = "Connection issue"
                NSLog("Could not activate Watch capture session: %@", error.localizedDescription)
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateConnection(session)
            requestCurrentState(session)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            receiveCaptureState(applicationContext)
            updateConnection(session)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let previewData = userInfo["preview"] as? Data,
              let image = UIImage(data: previewData) else { return }
        Task { @MainActor in previewImage = Image(uiImage: image) }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if let previewData = message["preview"] as? Data,
           let image = UIImage(data: previewData) {
            Task { @MainActor in previewImage = Image(uiImage: image) }
        }
        if message["recording"] is Bool || message["canStart"] is Bool {
            Task { @MainActor in receiveCaptureState(message) }
        }
        replyHandler(["accepted": true])
    }

    private func requestCurrentState(_ session: WCSession) {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["requestState": true], replyHandler: { [weak self] reply in
            Task { @MainActor in self?.receiveCaptureState(reply) }
        }, errorHandler: nil)
    }

    private func receiveCaptureState(_ context: [String: Any]) {
        isRecording = context["recording"] as? Bool ?? false
        canStartCapture = context["canStart"] as? Bool ?? false
        if let diagnostic = context["diagnostic"] as? String, !diagnostic.isEmpty {
            phoneDiagnostic = diagnostic
        }
        if let previewData = context["preview"] as? Data,
           let image = UIImage(data: previewData) {
            previewImage = Image(uiImage: image)
        }
    }

    private func updateConnection(_ session: WCSession) {
        isPhoneReachable = session.activationState == .activated && session.isReachable
        if !phoneDiagnostic.isEmpty && !phoneDiagnostic.hasPrefix("Phone ready") {
            status = phoneDiagnostic
        } else if isRecording {
            status = "Swing armed — swing now"
        } else if isPhoneReachable && canStartCapture {
            status = "Ready for swing"
        } else if isPhoneReachable {
            status = "Waiting for iPhone Range"
        } else {
            status = "Open GolfMonitor on iPhone"
        }
    }
}

struct WatchRemoteView: View {
    @StateObject private var model = WatchRemoteModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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

                Button(action: model.openPhoneCamera) {
                    Label("OPEN PHONE CAMERA", systemImage: "camera.viewfinder")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                if let previewImage = model.previewImage {
                    previewImage
                        .resizable()
                        .scaledToFill()
                        .frame(height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("WAITING FOR PHONE CAMERA")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .foregroundStyle(.secondary)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }

                Button(action: model.sendCaptureCommand) {
                    VStack(spacing: 5) {
                        Image(systemName: model.isRecording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 31, weight: .semibold))
                        Text(model.isRecording ? "END SWING" : "START SWING")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(model.isRecording ? Color.red : Color.orange, in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(model.isPhoneReachable ? 1 : 0.75)
                .accessibilityLabel(model.isRecording ? "End swing recording" : "Start swing recording")
            }
            .padding(.horizontal, 8)
        }
    }
}
