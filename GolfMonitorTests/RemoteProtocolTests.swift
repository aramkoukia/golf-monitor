import XCTest
@testable import GolfMonitor

/// The phone ↔ watch protocol (shared with the watch app) and the watch's
/// screen model.
final class RemoteProtocolTests: XCTestCase {
    func testRequestRoundTripsThroughAWatchConnectivityDictionary() throws {
        let request = RemoteRequest(command: .selectClub, argument: "7 Iron")
        let message = RemoteWire.message(request, kind: .request)
        XCTAssertTrue(message[RemoteWire.payloadKey] is Data, "property-list safe")
        let decoded = try XCTUnwrap(RemoteWire.decode(RemoteRequest.self, from: message, kind: .request))
        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.command, .selectClub)
        XCTAssertEqual(decoded.argument, "7 Iron")
        XCTAssertEqual(decoded.sentAt.timeIntervalSince1970, request.sentAt.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertNil(RemoteWire.decode(RemoteRequest.self, from: message, kind: .state), "kind must match")
        XCTAssertNil(RemoteWire.decode(RemoteRequest.self, from: ["junk": 1], kind: .request))
    }

    func testStateRoundTripIsSmall() throws {
        var state = RemoteState.placeholder()
        state.phase = .result
        state.lastShot = RemoteShotSummary(club: "Driver", clubShort: "DR", hasLaunchData: true, carry: 231,
                                           ballSpeed: 151, clubSpeed: 104, launchAngle: 12.4, smash: nil, tempo: 3.1,
                                           distanceUnit: "YDS", speedUnit: "MPH", practiceSwings: 2, shotsFound: 1,
                                           headline: "231 yds carry", savedToPhotos: true)
        state.ballLocksSeen = 3
        state.sentAt = Date(timeIntervalSince1970: 1_800_000_000.123)
        let message = RemoteWire.message(state, kind: .state)
        XCTAssertLessThan((message[RemoteWire.payloadKey] as? Data)?.count ?? .max, 1_500)
        XCTAssertEqual(RemoteWire.decode(RemoteState.self, from: message, kind: .state), state)
    }

    func testStaleRequestsAreRejected() {
        XCTAssertTrue(RemoteWire.isFresh(RemoteRequest(command: .start)))
        XCTAssertFalse(RemoteWire.isFresh(RemoteRequest(command: .start, sentAt: Date().addingTimeInterval(-60))))
    }

    func testPreviewLeaseExpires() {
        var lease = PreviewLease()
        let now = Date()
        XCTAssertFalse(lease.isActive(now: now))
        lease.renew(now: now)
        XCTAssertTrue(lease.isActive(now: now.addingTimeInterval(RemoteWire.previewLease - 0.1)))
        XCTAssertFalse(lease.isActive(now: now.addingTimeInterval(RemoteWire.previewLease + 0.1)))
        lease.renew(now: now)
        lease.revoke()
        XCTAssertFalse(lease.isActive(now: now))
        XCTAssertLessThan(RemoteWire.previewRenewInterval, RemoteWire.previewLease, "renewed before it lapses")
    }

    func testNewerStatesWinAndANewPhoneSessionResets() {
        var a = RemoteState.placeholder()
        a.revision = 5
        var b = a
        b.revision = 6
        XCTAssertTrue(b.supersedes(a))
        XCTAssertFalse(a.supersedes(b))
        var relaunched = RemoteState.placeholder()
        relaunched.revision = 1
        relaunched.sentAt = a.sentAt.addingTimeInterval(1)
        XCTAssertTrue(relaunched.supersedes(b), "new epoch: the phone app restarted")
        XCTAssertTrue(a.supersedes(nil))
    }

    func testLedgerReplaysAndForgets() {
        var ledger = RemoteRequestLedger()
        ledger.capacity = 2
        let ids = [UUID(), UUID(), UUID()]
        for id in ids { ledger.record(RemoteReply(accepted: true, reason: nil, state: nil), for: id) }
        XCTAssertNil(ledger.reply(for: ids[0]), "oldest dropped")
        XCTAssertNotNil(ledger.reply(for: ids[2]))
    }

    // MARK: Watch screen

    private func state(_ phase: RemotePhase, configure: (inout RemoteState) -> Void = { _ in }) -> RemoteState {
        var s = RemoteState.placeholder()
        s.phase = phase
        configure(&s)
        return s
    }

    func testScreenWhenPhoneUnreachable() {
        let screen = RemoteScreenModel.make(state: state(.ready), reachable: false)
        XCTAssertFalse(screen.isConnected)
        XCTAssertEqual(screen.primary, .none)
        XCTAssertFalse(screen.wantsPreview)
    }

    func testScreenPerPhase() {
        XCTAssertEqual(RemoteScreenModel.make(state: state(.notReady), reachable: true).primary, .none)
        let ready = RemoteScreenModel.make(state: state(.ready) { $0.ballLocked = true }, reachable: true)
        XCTAssertEqual(ready.primary, .start)
        XCTAssertEqual(ready.title, "Ball locked")
        XCTAssertTrue(ready.wantsPreview)
        let rec = RemoteScreenModel.make(state: state(.recording) { $0.swingsDetected = 2 }, reachable: true)
        XCTAssertEqual(rec.primary, .stop)
        XCTAssertEqual(rec.tone, .live)
        XCTAssertTrue(rec.detail.contains("2 swings"))
        let shot = RemoteScreenModel.make(state: state(.recording) { $0.shotsDetected = 1 }, reachable: true)
        XCTAssertTrue(shot.detail.contains("Shot detected"))
        XCTAssertFalse(RemoteScreenModel.make(state: state(.processing), reachable: true).wantsPreview)
        XCTAssertEqual(RemoteScreenModel.make(state: state(.result), reachable: true).primary, .nextShot)
        XCTAssertEqual(RemoteScreenModel.make(state: state(.error), reachable: true).tone, .warning)
    }

    // MARK: Ball-lock tap

    func testBallLockTapsOncePerNewlyLockedBall() {
        var cue = BallLockCue()
        let now = Date()
        var before = state(.ready) { $0.ballLocksSeen = 0; $0.sentAt = now }
        var locked = before
        locked.ballLocked = true
        locked.ballLocksSeen = 1
        XCTAssertTrue(cue.shouldTap(previous: before, incoming: locked, now: now))

        // Golfer stands over the ball, then steps away: same ball, no tap.
        var hidden = locked
        hidden.ballLocked = false
        hidden.sentAt = now.addingTimeInterval(5)
        var back = locked
        back.sentAt = now.addingTimeInterval(6)
        XCTAssertFalse(cue.shouldTap(previous: locked, incoming: hidden, now: hidden.sentAt))
        XCTAssertFalse(cue.shouldTap(previous: hidden, incoming: back, now: back.sentAt))

        // The next teed ball, while recording.
        before = state(.recording) { $0.ballLocksSeen = 1; $0.sentAt = now.addingTimeInterval(10) }
        var next = before
        next.ballLocksSeen = 2
        XCTAssertTrue(cue.shouldTap(previous: before, incoming: next, now: now.addingTimeInterval(10)))
    }

    func testBallLockTapIsRateLimitedAndOnlyWhileTheCameraIsLive() {
        var cue = BallLockCue()
        let now = Date()
        func pair(_ phase: RemotePhase, from: Int, to: Int, sent: Date = now) -> (RemoteState, RemoteState) {
            let a = state(phase) { $0.ballLocksSeen = from; $0.sentAt = sent }
            var b = a
            b.ballLocksSeen = to
            return (a, b)
        }
        var (a, b) = pair(.ready, from: 0, to: 2)
        XCTAssertTrue(cue.shouldTap(previous: a, incoming: b, now: now), "two loose balls lock together: one tap")
        (a, b) = pair(.ready, from: 2, to: 3)
        XCTAssertFalse(cue.shouldTap(previous: a, incoming: b, now: now.addingTimeInterval(1)), "within 2 s of the last tap")

        var fresh = BallLockCue()
        (a, b) = pair(.processing, from: 0, to: 1)
        XCTAssertFalse(fresh.shouldTap(previous: a, incoming: b, now: now))
        (a, b) = pair(.result, from: 0, to: 1)
        XCTAssertFalse(fresh.shouldTap(previous: a, incoming: b, now: now))
        (a, b) = pair(.ready, from: 0, to: 1, sent: now.addingTimeInterval(-10))
        XCTAssertFalse(fresh.shouldTap(previous: a, incoming: b, now: now), "stale: arrived when the wrist came up")
        (a, b) = pair(.ready, from: 0, to: 1)
        XCTAssertFalse(fresh.shouldTap(previous: nil, incoming: b, now: now), "first state after connecting")
        var relaunched = b
        relaunched.epoch = UUID()
        XCTAssertFalse(fresh.shouldTap(previous: a, incoming: relaunched, now: now), "phone app restarted")
        a.ballLocksSeen = nil
        b.ballLocksSeen = nil
        XCTAssertFalse(fresh.shouldTap(previous: a, incoming: b, now: now), "older phone without the count")
    }

    func testFormatting() {
        XCTAssertEqual(RemoteFormat.clock(7.9), "0:07")
        XCTAssertEqual(RemoteFormat.clock(165), "2:45")
        XCTAssertEqual(RemoteFormat.clock(-3), "0:00")
        XCTAssertEqual(RemoteFormat.number(151.6), "152")
        XCTAssertEqual(RemoteFormat.number(nil), "—")
        XCTAssertEqual(RemoteFormat.number(12.44, digits: 1), "12.4")
    }
}
