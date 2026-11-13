import Foundation

// Wire protocol between the iPhone (camera, recording, on-device analysis)
// and the Apple Watch (remote control + live preview). This file is compiled
// into BOTH the iOS app and the watchOS app, so the two always agree.
//
// Transport (WatchConnectivity):
//  • watch → phone  `sendMessage` carrying a `RemoteRequest`; the phone
//    replies with a `RemoteReply` that includes its current `RemoteState`.
//  • phone → watch  `sendMessage` (when reachable) and
//    `updateApplicationContext` (always) carrying a `RemoteState`.
//  • phone → watch  `sendMessageData` carrying one JPEG preview frame. Only
//    preview frames use message *data*, so no envelope is needed.
//
// Commands are never queued with `transferUserInfo`: a "start recording"
// delivered minutes late would be worse than a clear "not reachable" error.

/// Something the watch asks the phone to do.
enum RemoteCommand: String, Codable, CaseIterable, Sendable {
    /// Start a continuous recording (set up, practice swings, real shot…).
    case start
    /// Stop recording and analyze the session.
    case stop
    /// Abort the current recording without analyzing it.
    case cancel
    /// Leave the result screen and get ready for the next shot.
    case dismissResult
    /// Ask for the latest state (no side effects).
    case requestState
    /// Keep streaming preview frames for a few more seconds (a lease).
    case subscribePreview
    /// Stop streaming preview frames now.
    case unsubscribePreview
    /// Change the club (argument = `Club.rawValue` on the phone).
    case selectClub
}

struct RemoteRequest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var command: RemoteCommand
    var sentAt: Date = Date()
    var argument: String? = nil
}

/// What the phone is doing, as seen by the watch.
enum RemotePhase: String, Codable, Sendable {
    /// Phone app is running but the camera isn't live (permissions, warming
    /// up, app in the background).
    case notReady
    /// Live camera, waiting for Start.
    case ready
    /// Recording the session.
    case recording
    /// Finding the shot and measuring it.
    case processing
    /// A result is on screen.
    case result
    /// Something went wrong; `message` says what.
    case error
}

/// The numbers the watch shows after a session. Values are already
/// converted to the user's display units.
struct RemoteShotSummary: Codable, Equatable, Sendable {
    var club: String
    var clubShort: String
    var hasLaunchData: Bool
    var carry: Double?
    var ballSpeed: Double?
    var clubSpeed: Double?
    var launchAngle: Double?
    var smash: Double?
    var tempo: Double?
    /// "YDS" / "M".
    var distanceUnit: String
    /// "MPH" / "KM/H".
    var speedUnit: String
    var practiceSwings: Int
    var shotsFound: Int
    /// One line for the result card ("Pure strike", "No ball strike found"…).
    var headline: String
    var savedToPhotos: Bool
}

/// Snapshot of the phone's range session. Small enough (< 1 KB) to send on
/// every change.
struct RemoteState: Codable, Equatable, Sendable {
    var phase: RemotePhase
    /// Short user-facing status line.
    var message: String
    var club: String
    var clubShort: String
    /// Seconds recorded so far, at `sentAt`. The watch derives its own start
    /// time from this, so phone/watch clock skew doesn't matter.
    var recordingElapsed: TimeInterval?
    var maxRecordingSeconds: TimeInterval
    /// 0...1 while processing.
    var progress: Double?
    /// A ball is locked in the hitting zone.
    var ballLocked: Bool
    /// Balls locked since the phone app started. Each newly teed ball counts
    /// once; a hidden ball coming back into view doesn't. nil from phones
    /// that predate it.
    var ballLocksSeen: Int?
    /// Whether a recording started now is likely to be caught and measured
    /// (camera live phases only). nil from phones that predate it.
    var readiness: RemoteReadiness?
    /// Live counts while recording.
    var swingsDetected: Int
    var shotsDetected: Int
    var lastShot: RemoteShotSummary?
    /// Capture frame rate, e.g. 240.
    var fps: Int
    /// Unique per phone-app launch; with `revision` orders updates.
    var epoch: UUID
    /// Increases with every published change.
    var revision: Int
    var sentAt: Date

    static func placeholder(epoch: UUID = UUID()) -> RemoteState {
        RemoteState(phase: .notReady, message: "Open GolfMonitor on your iPhone",
                    club: "Driver", clubShort: "DR", recordingElapsed: nil,
                    maxRecordingSeconds: 300, progress: nil, ballLocked: false,
                    swingsDetected: 0, shotsDetected: 0, lastShot: nil, fps: 0,
                    epoch: epoch, revision: 0, sentAt: Date())
    }

    /// True if `self` should replace `current` (newer revision of the same
    /// phone session, or a new phone session altogether).
    func supersedes(_ current: RemoteState?) -> Bool {
        guard let current else { return true }
        if epoch != current.epoch { return sentAt >= current.sentAt }
        return revision > current.revision
    }
}

/// Whether a recording started now is likely to be caught and measured.
/// Worked out on the phone from what the camera sees, shown on the phone and
/// the watch. Advisory: recording is never blocked.
enum RemoteReadiness: String, Codable, Sendable, CaseIterable {
    /// Ball locked with room to fly and enough light: ball numbers expected.
    case ready
    /// Down the line: the swing is analyzed, the ball isn't.
    case readySwingOnly
    /// Face-on, but no ball is locked: a swing would get swing analysis only.
    case noBall
    /// The ball is so close to the edge it flies out of that it would leave
    /// the frame before it can be tracked.
    case ballAtEdge
    /// Too dark for the fixed fast shutter: the ball may not be tracked.
    case tooDark
    /// The phone moved after a ball was locked, so the calibration baseline
    /// is no longer valid. Re-tee or wait for the ball to re-lock.
    case phoneMoved

    var isReady: Bool { self == .ready || self == .readySwingOnly }

    /// Short status label.
    var label: String {
        switch self {
        case .ready: return "READY TO SWING"
        case .readySwingOnly: return "READY · SWING ONLY"
        case .noBall: return "NO BALL LOCKED"
        case .ballAtEdge: return "MOVE BALL"
        case .tooDark: return "TOO DARK"
        case .phoneMoved: return "PHONE MOVED"
        }
    }

    /// One line on what it means / what to do.
    var hint: String {
        switch self {
        case .ready: return "Ball locked with room to fly. Start when you're ready."
        case .readySwingOnly: return "Down the line: your swing is analyzed. Switch to face-on for ball numbers."
        case .noBall: return "Tee a ball in view — your wrist taps when it locks."
        case .ballAtEdge: return "The ball is near the edge it flies out of. Give it room in front."
        case .tooDark: return "Too dark for the fast shutter. Add light, or set Shutter to Auto."
        case .phoneMoved: return "The phone moved after the ball locked — step back so the ball re-locks."
        }
    }
}

/// When the watch taps to say "ball locked, you can swing": once per newly
/// locked ball while the camera is live (ready or recording), never for a
/// hidden ball coming back into view, at most once every `minInterval`
/// (several loose balls locking together), and only for fresh news: a
/// state that waited for the wrist to come up is already on screen.
struct BallLockCue {
    var minInterval: TimeInterval = 2
    var maxAge: TimeInterval = 4
    private(set) var lastCue: Date?

    mutating func shouldTap(previous: RemoteState?, incoming: RemoteState, now: Date = Date()) -> Bool {
        guard let previous, previous.epoch == incoming.epoch,
              incoming.phase == .ready || incoming.phase == .recording,
              (incoming.ballLocksSeen ?? 0) > (previous.ballLocksSeen ?? 0),
              now.timeIntervalSince(incoming.sentAt) < maxAge else { return false }
        if let lastCue, now.timeIntervalSince(lastCue) < minInterval { return false }
        lastCue = now
        return true
    }
}

struct RemoteReply: Codable, Equatable, Sendable {
    var accepted: Bool
    var reason: String?
    var state: RemoteState?
}

/// Encodes protocol values into WatchConnectivity dictionaries.
enum RemoteWire {
    enum Kind: String { case request, reply, state }

    static let kindKey = "gm.kind"
    static let payloadKey = "gm.payload"
    /// A request older than this is ignored (e.g. delivered after a long
    /// Bluetooth stall), so a stale "start" never fires.
    static let requestTTL: TimeInterval = 20
    /// How long one `subscribePreview` keeps frames flowing.
    static let previewLease: TimeInterval = 6
    /// The watch renews its lease this often while the preview is visible.
    static let previewRenewInterval: TimeInterval = 3

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    static func message<T: Encodable>(_ value: T, kind: Kind) -> [String: Any] {
        guard let data = try? encoder.encode(value) else { return [:] }
        return [kindKey: kind.rawValue, payloadKey: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any], kind: Kind) -> T? {
        guard message[kindKey] as? String == kind.rawValue,
              let data = message[payloadKey] as? Data else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func isFresh(_ request: RemoteRequest, now: Date = Date()) -> Bool {
        abs(now.timeIntervalSince(request.sentAt)) <= requestTTL
    }
}

/// Keeps preview frames flowing only while the watch keeps asking for them,
/// so a watch that drops its wrist (or crashes) stops costing phone CPU.
struct PreviewLease: Equatable, Sendable {
    private(set) var expiresAt: Date = .distantPast

    mutating func renew(now: Date = Date(), duration: TimeInterval = RemoteWire.previewLease) {
        expiresAt = now.addingTimeInterval(duration)
    }

    mutating func revoke() { expiresAt = .distantPast }

    func isActive(now: Date = Date()) -> Bool { now < expiresAt }
}
