import SwiftUI
import Combine
import UIKit
import WatchConnectivity

@MainActor
final class WatchRemoteModel: NSObject, ObservableObject, @preconcurrency WCSessionDelegate {
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var isRecording = false
    @Published private(set) var canStartCapture = false
    @Published private(set) var previewImage: Image?
    @Published private(set) var previewOn = false
    @Published private(set) var status = "Connecting…"

    private var refreshTimer: Timer?

    override init() {
        super.init()
        guard WCSession.isSupported() else { status = "Watch unavailable"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendCaptureCommand() {
        if isRecording { sendCommand(WatchConnectivityConstants.stop); if previewOn { setPreview(false) } }
        else { sendCommand(WatchConnectivityConstants.start) }
    }

    func openPhoneCamera() {
        sendCommand(WatchConnectivityConstants.openCamera)
        status = "Open GolfMonitor on iPhone → Session"
    }

    func setPreview(_ on: Bool) {
        previewOn = on
        if !on { previewImage = nil }
        sendCommand(on ? WatchConnectivityConstants.previewOn : WatchConnectivityConstants.previewOff)
        refreshTimer?.invalidate()
        refreshTimer = nil
        if on {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sendCommand(WatchConnectivityConstants.previewOn) }
            }
        }
    }

    func viewDisappeared() {
        if previewOn { setPreview(false) }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func sendCommand(_ command: String) {
        let session = WCSession.default
        let requestID = UUID().uuidString
        let timestamp = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            WatchConnectivityConstants.command: command,
            WatchConnectivityConstants.requestID: requestID,
            WatchConnectivityConstants.timestamp: timestamp
        ]

        guard session.activationState == .activated else {
            session.activate()
            status = "Connecting…"
            return
        }
        guard session.isReachable else {
            session.transferUserInfo(payload)
            status = "iPhone not reachable"
            return
        }

        status = command == WatchConnectivityConstants.previewOn || command == WatchConnectivityConstants.previewOff
            ? status : (command == WatchConnectivityConstants.start ? "Starting swing…" : "Ending swing…")
        session.sendMessage(payload, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                if reply[WatchConnectivityConstants.accepted] as? Bool == true {
                    if command == WatchConnectivityConstants.start { self.isRecording = true; if self.previewOn { self.setPreview(false) } }
                    if command == WatchConnectivityConstants.stop { self.isRecording = false }
                    self.updateStatus()
                    self.requestCurrentState(session)
                } else {
                    self.status = reply[WatchConnectivityConstants.reason] as? String ?? "Phone could not complete the command"
                }
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.status = "Command failed: \(error.localizedDescription)"
            }
        })
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            receiveCaptureState(session.receivedApplicationContext)
            updateConnection(session)
            requestCurrentState(session)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateConnection(session)
            if !session.isReachable {
                refreshTimer?.invalidate(); refreshTimer = nil
                previewOn = false; previewImage = nil
            } else { requestCurrentState(session) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in receiveCaptureState(applicationContext); updateConnection(session) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleFrame(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleFrame(message)
        receiveCaptureState(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleFrame(message)
        receiveCaptureState(message)
        replyHandler([WatchConnectivityConstants.accepted: true])
    }

    private func handleFrame(_ message: [String: Any]) {
        guard let previewData = message[WatchConnectivityConstants.preview] as? Data,
              let image = UIImage(data: previewData) else { return }
        Task { @MainActor in previewImage = Image(uiImage: image) }
    }

    private func requestCurrentState(_ session: WCSession) {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([WatchConnectivityConstants.requestState: true], replyHandler: { [weak self] reply in
            Task { @MainActor in self?.receiveCaptureState(reply) }
        }, errorHandler: nil)
    }

    private func receiveCaptureState(_ context: [String: Any]) {
        if let recording = context[WatchConnectivityConstants.recording] as? Bool { isRecording = recording }
        if let canStart = context[WatchConnectivityConstants.canStart] as? Bool { canStartCapture = canStart }
        updateStatus()
    }

    private func updateConnection(_ session: WCSession) {
        isPhoneReachable = session.activationState == .activated && session.isReachable
        updateStatus()
    }

    private func updateStatus() {
        guard !isRecording else { status = "Swing recording"; return }
        if !isPhoneReachable { status = "iPhone not reachable"; return }
        if canStartCapture { status = "Ready for swing" }
        else { status = "Open GolfMonitor on iPhone → Session" }
    }
}

struct WatchRemoteView: View {
    @StateObject private var model = WatchRemoteModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(model.isPhoneReachable ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(model.status.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.7)
                }.foregroundStyle(.secondary)

                Button(action: { model.openPhoneCamera() }) {
                    Label("OPEN PHONE CAMERA", systemImage: "camera.viewfinder")
                        .font(.system(size: 9, weight: .bold, design: .rounded)).frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(.blue)

                if model.previewOn, let previewImage = model.previewImage {
                    previewImage.resizable().scaledToFit().frame(height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button("HIDE CAMERA") { model.setPreview(false) }.buttonStyle(.bordered)
                } else {
                    Button(model.previewOn ? "Connecting camera…" : "SHOW CAMERA") {
                        if !model.previewOn { model.setPreview(true) }
                    }.buttonStyle(.borderedProminent).disabled(model.previewOn)
                }

                Button(action: model.sendCaptureCommand) {
                    VStack(spacing: 4) {
                        Image(systemName: model.isRecording ? "stop.fill" : "record.circle.fill").font(.system(size: 31, weight: .semibold))
                        Text(model.isRecording ? "END SWING" : "START SWING").font(.system(size: 10, weight: .black, design: .rounded))
                    }.foregroundStyle(.white).frame(width: 110, height: 110)
                        .background(model.isRecording ? Color.red : Color.orange, in: Circle())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 8)
        }
        .onDisappear { model.viewDisappeared() }
    }
}
