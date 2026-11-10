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
