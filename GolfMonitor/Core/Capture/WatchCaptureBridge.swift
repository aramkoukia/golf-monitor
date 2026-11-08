import Combine
import CoreImage
import CoreMedia
import Foundation
import QuartzCore
import UIKit
import WatchConnectivity

extension Notification.Name {
    static let watchCaptureOpenRange = Notification.Name("GolfMonitorWatchCaptureOpenRange")
}

final class WatchCaptureBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchCaptureBridge()

    @Published private(set) var isPaired = false
    @Published private(set) var isReachable = false
    @Published private(set) var isRecording = false
    @Published private(set) var canStartCapture = false
    var commandHandler: ((String) -> (accepted: Bool, reason: String?))? {
        didSet {
            if commandHandler != nil { flushPendingCommands() }
        }
    }

    private let previewContext = CIContext()
    private let previewQueue = DispatchQueue(label: "golfmonitor.watch.preview", qos: .utility)
    private var lastPreviewSentAt: TimeInterval = 0
    private var previewData: Data?
    private var pendingCommands: [String] = []

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

    func sendPreview(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewSentAt >= 1.0 else { return }
        lastPreviewSentAt = now

        previewQueue.async { [weak self] in
            guard let self,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = min(320 / image.extent.width, 320 / image.extent.height)
            let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = self.previewContext.createCGImage(scaledImage, from: scaledImage.extent) else { return }
            let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.5)

            if let data {
                DispatchQueue.main.async {
                    self.previewData = data
                    self.updateApplicationContext()

                    let session = WCSession.default
                    session.transferUserInfo(["preview": data])
                    if session.activationState == .activated && session.isReachable {
                        session.sendMessage(["preview": data], replyHandler: nil) { error in
                            NSLog("Live watch preview delivery failed: %@", error.localizedDescription)
                        }
                    }
                }
            }
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

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = userInfo["command"] as? String,
              command == "start" || command == "stop" else { return }
        DispatchQueue.main.async {
            self.handleCommand(command)
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message["requestState"] as? Bool == true {
            replyHandler([
                "recording": isRecording,
                "canStart": canStartCapture,
                "preview": previewData as Any
            ])
            return
        }
        guard let command = message["command"] as? String,
              command == "start" || command == "stop" else {
            replyHandler(["accepted": false, "reason": "Unknown command"])
            return
        }
        DispatchQueue.main.async {
            let response = self.handleCommand(command)
            NSLog("Watch command live: %@ accepted=%@ reason=%@", command,
                  response.accepted ? "yes" : "no", response.reason ?? "")
            self.updateApplicationContext()
            replyHandler([
                "accepted": response.accepted,
                "reason": response.reason ?? ""
            ])
        }
    }

    private func handleCommand(_ command: String) -> (accepted: Bool, reason: String?) {
        NotificationCenter.default.post(name: .watchCaptureOpenRange, object: nil)

        guard let commandHandler else {
            if pendingCommands.last != command { pendingCommands.append(command) }
            return (true, "Opening GolfMonitor Range on the iPhone.")
        }

        let response = commandHandler(command)
        updateApplicationContext()
        return response
    }

    private func flushPendingCommands() {
        guard let commandHandler else { return }
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands {
            let response = commandHandler(command)
            NSLog("Watch command pending: %@ accepted=%@ reason=%@", command,
                  response.accepted ? "yes" : "no", response.reason ?? "")
        }
        updateApplicationContext()
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
            var context: [String: Any] = [
                "recording": isRecording,
                "canStart": canStartCapture,
                "phoneReachable": WCSession.default.isReachable,
                "watchPaired": WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
            ]
            if let previewData { context["preview"] = previewData }
            try WCSession.default.updateApplicationContext(context)
        } catch {
            NSLog("Could not update Watch capture state: %@", error.localizedDescription)
        }
    }
}
