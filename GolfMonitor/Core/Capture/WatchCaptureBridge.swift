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
    @Published private(set) var previewStreamingRequested = false

    var openRangeHandler: (() -> Void)?
    var commandHandler: ((String) -> (accepted: Bool, reason: String?))?

    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])
    private let previewQueue = DispatchQueue(label: "golfmonitor.watch.preview", qos: .utility)
    private var previewSendInFlight = false
    private var previewRequestedAt: TimeInterval = 0
    private var lastPreviewSentAt: TimeInterval = 0
    private var commandResults: [String: (accepted: Bool, reason: String?)] = [:]
    private var diagnostic = "Phone ready"

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self { session.delegate = self }
        if session.activationState == .activated { refreshState() } else { session.activate() }
    }

    func updateCaptureState(isRecording recording: Bool, canStart: Bool) {
        DispatchQueue.main.async {
            self.isRecording = recording
            self.canStartCapture = canStart
            self.diagnostic = recording ? "Recording on phone" : (canStart ? "Phone camera ready" : "Waiting for phone camera")
            if recording { self.setPreviewRequested(false) }
            self.updateApplicationContext()
        }
    }

    func setPreviewRequested(_ requested: Bool) {
        previewRequestedAt = requested ? CACurrentMediaTime() : 0
        previewStreamingRequested = requested
        if !requested { previewSendInFlight = false }
    }

    func refreshPreviewRequest() {
        guard previewStreamingRequested else { return }
        previewRequestedAt = CACurrentMediaTime()
    }

    func sendPreview(_ sampleBuffer: CMSampleBuffer) {
        guard previewStreamingRequested else { return }
        guard CACurrentMediaTime() - previewRequestedAt < WatchConnectivityConstants.commandTTL else {
            DispatchQueue.main.async { self.setPreviewRequested(false) }
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastPreviewSentAt >= 0.2 else { return }
        guard !previewSendInFlight else { return }
        lastPreviewSentAt = now
        previewSendInFlight = true

        previewQueue.async { [weak self] in
            guard let self,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    DispatchQueue.main.async { self?.previewSendInFlight = false }
                    return
                  }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = min(240 / max(image.extent.width, 1), 240 / max(image.extent.height, 1))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = self.previewContext.createCGImage(scaled, from: scaled.extent),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.4) else {
                DispatchQueue.main.async { self.previewSendInFlight = false }
                return
            }
            DispatchQueue.main.async {
                let session = WCSession.default
                guard self.previewStreamingRequested,
                      session.activationState == .activated,
                      session.isReachable else {
                    self.previewSendInFlight = false
                    return
                }
                session.sendMessage(
                    [WatchConnectivityConstants.preview: data],
                    replyHandler: { [weak self] _ in
                        DispatchQueue.main.async { self?.previewSendInFlight = false }
                    },
                    errorHandler: { [weak self] _ in
                        DispatchQueue.main.async { self?.previewSendInFlight = false }
                    }
                )
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.refreshState(); self.updateApplicationContext() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshState()
            if !session.isReachable { self.setPreviewRequested(false) }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = userInfo[WatchConnectivityConstants.command] as? String else { return }
        let requestID = userInfo[WatchConnectivityConstants.requestID] as? String
        handlePayload(command: command, requestID: requestID, timestamp: userInfo[WatchConnectivityConstants.timestamp] as? TimeInterval)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message[WatchConnectivityConstants.requestState] as? Bool == true {
            replyHandler([WatchConnectivityConstants.recording: isRecording,
                          WatchConnectivityConstants.canStart: canStartCapture,
                          WatchConnectivityConstants.diagnostic: diagnostic,
                          WatchConnectivityConstants.phoneReachable: true])
            return
        }
        guard let command = message[WatchConnectivityConstants.command] as? String else {
            replyHandler([WatchConnectivityConstants.accepted: false, WatchConnectivityConstants.reason: "Unknown command"])
            return
        }
        let response = handlePayload(command: command,
                                     requestID: message[WatchConnectivityConstants.requestID] as? String,
                                     timestamp: message[WatchConnectivityConstants.timestamp] as? TimeInterval)
        replyHandler([WatchConnectivityConstants.accepted: response.accepted,
                      WatchConnectivityConstants.reason: response.reason ?? ""])
    }

    private func handlePayload(command: String, requestID: String?, timestamp: TimeInterval?) -> (accepted: Bool, reason: String?) {
        if let timestamp, Date().timeIntervalSince1970 - timestamp > WatchConnectivityConstants.commandTTL {
            return (false, "Command expired — tap Start Swing again")
        }
        if command == WatchConnectivityConstants.previewOn {
            setPreviewRequested(true)
            return (true, nil)
        }
        if command == WatchConnectivityConstants.previewOff {
            setPreviewRequested(false)
            return (true, nil)
        }
        if requestID == nil || timestamp == nil { return (false, "Invalid command timestamp") }
        if let requestID, let cached = commandResults[requestID] { return cached }

        diagnostic = "Phone received \(command)"
        updateApplicationContext()

        if command == WatchConnectivityConstants.openCamera {
            openRangeHandler?()
            NotificationCenter.default.post(name: .watchCaptureOpenRange, object: nil)
            if let url = URL(string: "golfmonitor://open-range") {
                DispatchQueue.main.async { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
            }
            return cache(requestID: requestID, response: (true, nil))
        }

        guard command == WatchConnectivityConstants.start || command == WatchConnectivityConstants.stop else {
            return (false, "Unknown command")
        }
        guard let commandHandler else {
            return (false, "Open GolfMonitor → Range and wait for the live camera")
        }
        let response = commandHandler(command)
        if response.accepted {
            isRecording = command == WatchConnectivityConstants.start
            canStartCapture = !isRecording
            updateApplicationContext()
        }
        return response.accepted ? cache(requestID: requestID, response: response) : response
    }

    private func cache(requestID: String?, response: (accepted: Bool, reason: String?)) -> (accepted: Bool, reason: String?) {
        if let requestID { commandResults[requestID] = response }
        if commandResults.count > 50 { commandResults.removeValue(forKey: commandResults.keys.first ?? "") }
        return response
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
                WatchConnectivityConstants.recording: isRecording,
                WatchConnectivityConstants.canStart: canStartCapture,
                WatchConnectivityConstants.phoneReachable: WCSession.default.isReachable,
                WatchConnectivityConstants.watchPaired: WCSession.default.isPaired && WCSession.default.isWatchAppInstalled,
                WatchConnectivityConstants.diagnostic: diagnostic
            ])
        } catch {
            NSLog("Could not update Watch capture state: %@", error.localizedDescription)
        }
    }
}
