import Foundation

/// What the watch should show, derived from the latest phone state and the
/// WatchConnectivity reachability. Pure value logic (unit-tested on iOS) so
/// the watch views stay declarative.
struct RemoteScreenModel: Equatable {
    enum PrimaryAction: Equatable {
        case start
        case stop
        case nextShot
        /// Nothing to press (connecting, analyzing…).
        case none
    }

    enum Tone: Equatable {
        /// Brand orange: ready to record.
        case plasma
        /// Recording.
        case live
        /// Analyzing / informational.
        case calm
        /// Good result.
        case success
        /// Needs the user's attention.
        case warning
    }

    var title: String
    var detail: String
    var primary: PrimaryAction
    var tone: Tone
    /// The preview is worth streaming (camera live, not analyzing).
    var wantsPreview: Bool
    var isConnected: Bool

    static func make(state: RemoteState?, reachable: Bool) -> RemoteScreenModel {
        guard reachable, let state else {
            return RemoteScreenModel(
                title: "iPhone not connected",
                detail: "Open GolfMonitor on your iPhone and keep it nearby.",
                primary: .none, tone: .warning, wantsPreview: false, isConnected: false)
        }
        switch state.phase {
        case .notReady:
            return RemoteScreenModel(
                title: "Camera not ready",
                detail: state.message.isEmpty ? "Open GolfMonitor on your iPhone." : state.message,
                primary: .none, tone: .warning, wantsPreview: false, isConnected: true)
        case .ready:
            return RemoteScreenModel(
                title: state.ballLocked ? "Ball locked" : "Ready",
                detail: state.ballLocked
                    ? "Start, take your practice swings, hit, then stop."
                    : "Start whenever you like — tee a ball in view.",
                primary: .start, tone: .plasma, wantsPreview: true, isConnected: true)
        case .recording:
            let detail: String
            if state.shotsDetected > 0 {
                detail = "Shot detected — tap stop when you're done."
            } else if state.swingsDetected > 0 {
                let n = state.swingsDetected
                detail = "\(n) swing\(n == 1 ? "" : "s") seen · hit when ready"
            } else {
                detail = "Set up, take practice swings, then hit."
            }
            return RemoteScreenModel(title: "Recording", detail: detail, primary: .stop,
                                     tone: .live, wantsPreview: true, isConnected: true)
        case .processing:
            return RemoteScreenModel(title: "Analyzing", detail: state.message,
                                     primary: .none, tone: .calm, wantsPreview: false, isConnected: true)
        case .result:
            let found = state.lastShot?.hasLaunchData == true
            return RemoteScreenModel(title: found ? "Shot measured" : "Swing saved",
                                     detail: state.lastShot?.headline ?? state.message,
                                     primary: .nextShot, tone: found ? .success : .calm,
                                     wantsPreview: false, isConnected: true)
        case .error:
            return RemoteScreenModel(title: "Something went wrong", detail: state.message,
                                     primary: .nextShot, tone: .warning, wantsPreview: false, isConnected: true)
        }
    }
}

enum RemoteFormat {
    /// "0:07", "2:45".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "152", "—".
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value)
    }
}
