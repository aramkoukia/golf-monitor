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
            if commandHandler != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.flushPendingCommands()
                }
            }
        }
    }

    private let previewContext = CIContext()
    private let previewQueue = DispatchQueue(label: "golfmonitor.watch.preview", qos: .utility)
    private var lastPreviewSentAt: TimeInterval = 0
    private var previewData: Data?
    private var pendingCommands: [String] = []
    private var commandResults: [String: (accepted: Bool, reason: String?)] = [:]
    private var diagnostic = "Phone ready"

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
            self.diagnostic = recording ? "Recording on phone" : (canStart ? "Phone camera ready" : "Waiting for phone camera")
            self.updateApplicationContext()
            if canStart { self.flushPendingCommands() }
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
                    if session.activationState == .activated && session.isReachable {
                        session.sendMessage(["preview": data], replyHandler: nil) { error in
                            NSLog("Live watch preview delivery failed: %@", error.localizedDescription)
                            session.transferUserInfo(["preview": data])
                        }
                    } else {
                        session.transferUserInfo(["preview": data])
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
              command == "start" || command == "stop" || command == "open_camera" else { return }
        let requestID = userInfo["requestID"] as? String
        DispatchQueue.main.async {
            _ = self.handleCommand(command, requestID: requestID)
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
                "preview": previewData as Any,
                "diagnostic": diagnostic,
                "phoneReachable": true
            ])
            return
        }
        guard let command = message["command"] as? String,
              command == "start" || command == "stop" || command == "open_camera" else {
            replyHandler(["accepted": false, "reason": "Unknown command"])
            return
        }
        let requestID = message["requestID"] as? String
        DispatchQueue.main.async {
            let response = self.handleCommand(command, requestID: requestID)
            NSLog("Watch command live: %@ accepted=%@ reason=%@", command,
                  response.accepted ? "yes" : "no", response.reason ?? "")
            self.updateApplicationContext()
            replyHandler([
                "accepted": response.accepted,
                "reason": response.reason ?? ""
            ])
        }
    }

    private func handleCommand(_ command: String, requestID: String? = nil) -> (accepted: Bool, reason: String?) {
        diagnostic = "Phone received \(command)"
        NSLog("Watch command received: %@ request=%@", command, requestID ?? "none")
        updateApplicationContext()
        if let requestID,
           let cached = commandResults[requestID] {
            return cached
        }

        NotificationCenter.default.post(name: .watchCaptureOpenRange, object: nil)

        if command == "open_camera" {
            diagnostic = "Opening iPhone Range"
            NotificationCenter.default.post(name: .watchCaptureOpenRange, object: nil)
            if let url = URL(string: "golfmonitor://open-range") {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
            schedulePendingRetry(attempts: 12)
            let response = (true, nil as String?)
            if let requestID { commandResults[requestID] = response }
            updateApplicationContext()
            return response
        }

        guard let commandHandler else {
            if pendingCommands.last != command { pendingCommands.append(command) }
            schedulePendingRetry(attempts: 12)
            // Rejection is intentionally not cached: a later live/durable delivery
            // may arrive after Range has mounted and should be allowed to retry.
            return (false, "Opening Range — wait for the live camera, then press Start Swing again.")
        }

        let response = commandHandler(command)
        if response.accepted {
            if command == "start" {
                isRecording = true
                canStartCapture = false
            } else {
                isRecording = false
                canStartCapture = true
            }
            updateApplicationContext()
        } else if command == "start" {
            if pendingCommands.last != command { pendingCommands.append(command) }
        }
        // Cache successful replies only; failures are never permanent so reconnects can recover.
        if response.accepted, let requestID {
            commandResults[requestID] = response
            if commandResults.count > 50 {
                commandResults.removeValue(forKey: commandResults.keys.first ?? "")
            }
        }
        updateApplicationContext()
        return response
    }

    private func schedulePendingRetry(attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if !self.pendingCommands.isEmpty { self.flushPendingCommands() }
            if !self.pendingCommands.isEmpty { self.schedulePendingRetry(attempts: attempts - 1) }
        }
    }

    private func flushPendingCommands() {
        guard let commandHandler else { return }
        var remaining: [String] = []
        for command in pendingCommands {
            let response = commandHandler(command)
            NSLog("Watch command pending: %@ accepted=%@ reason=%@", command,
                  response.accepted ? "yes" : "no", response.reason ?? "")
            if !response.accepted { remaining.append(command) }
        }
        pendingCommands = remaining
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
                "watchPaired": WCSession.default.isPaired && WCSession.default.isWatchAppInstalled,
                "diagnostic": diagnostic
            ]
            if let previewData { context["preview"] = previewData }
            try WCSession.default.updateApplicationContext(context)
        } catch {
            NSLog("Could not update Watch capture state: %@", error.localizedDescription)
        }
    }
}
