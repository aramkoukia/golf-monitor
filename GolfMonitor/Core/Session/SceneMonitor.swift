import CoreGraphics
import CoreVideo
import Foundation

/// Watches camera frames for the two signals the shot finder needs:
///
///  1. **Motion energy** — mean frame-to-frame brightness change on a coarse
///     grid. Swings (practice or real) show up as short, strong bursts.
///  2. **Ball presence** — the bundled GolfDetector locates stationary balls
///     (no separate "detect ball" step: it just runs in the background); each
///     locked ball's bright disk is then compared to its reference patch at
///     30 Hz. A ball that vanishes during a swing burst was struck, which is
///     how the real shot is told apart from practice swings.
///
/// Cheap enough to run on every recorded 240 fps session: it samples ~30
/// frames a second, reads < 2,000 luma values per frame and runs the detector
/// at most twice a second, on a copy of the frame and off the camera queue.
///
/// `ingest` must always be called from the same serial queue (the camera's
/// video queue, or the scanner's reading loop).
final class SceneMonitor {
    struct Config {
        /// Seconds between analyzed frames (~30 Hz).
        var analysisInterval: Double = 1.0 / 30
        /// Seconds between detector passes while fewer than `maxLocks` balls are visible.
        var locateInterval: Double = 0.5
        var gridColumns = 40
        var gridRows = 40
        /// Patch difference above which the ball counts as "not there".
        var absentThreshold: Float = 0.14
        /// A ball missing this long is "gone" (a new ball may be locked there).
        var goneAfter: Double = 1.0
        /// A gone ball that is visible again this long was only hidden.
        var returnAfter: Double = 0.3
        /// Stop watching a gone ball after this long.
        var forgetAfter: Double = 8
        var maxLocks = 6
        /// Consecutive detector passes a ball must sit still for before it's locked.
        var confirmations = 3
        /// Seconds of history kept in memory.
        var retention: Double = 20 * 60
        /// Seconds between UI snapshots.
        var snapshotInterval: Double = 0.15
        /// Run the detector inline (offline scanning) instead of on a background queue.
        var synchronousDetection = false
    }

    /// Called on the main queue with throttled overlay data.
    var onSnapshot: ((SceneSnapshot) -> Void)?

    private let config: Config
    private let locator: BallLocating
    private let detectionQueue = DispatchQueue(label: "golfmonitor.scene.detect", qos: .utility)
    private let lock = NSLock()

    // Confined to the ingest queue.
    private var previousGrid: [UInt8]?
    private var lastAnalysisTime = -Double.infinity
    private var lastSnapshotTime = -Double.infinity
    private var frameSize: (width: Int, height: Int) = (0, 0)
    private let copier = PixelBufferCopier()

    // Guarded by `lock`.
    private var motion: [MotionSample] = []
    private var tracks: [BallTrack] = []
    private var watched: [WatchedBall] = []
    private var pending: [PendingBall] = []
    private var lastLocateTime = -Double.infinity
    private var detectionInFlight = false
    private var lockQueue: [(candidate: BallCandidate, time: Double)] = []
    private var referenceRefreshPending = false

    private struct PendingBall {
        var candidate: BallCandidate
        var sightings: Int
    }

    private struct WatchedBall {
        var trackIndex: Int
        var reference: [UInt8]
        var radius: Double
        var absentSince: Double?
        var presentSince: Double?
        var isGone = false
    }

    init(config: Config = Config(), locator: BallLocating = GolfBallLocator()) {
        self.config = config
        self.locator = locator
    }

    // MARK: Ingest

    /// Feeds one upright frame captured at `time` (seconds, monotonic).
    func ingest(_ pixelBuffer: CVPixelBuffer, time: Double) {
        guard time - lastAnalysisTime >= config.analysisInterval * 0.9 else { return }
        lastAnalysisTime = time

        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        if width != frameSize.width || height != frameSize.height {
            frameSize = (width, height)
            previousGrid = nil
            lock.withLock { forgetAllBalls() }
        }

        PixelBufferLuma.with(pixelBuffer) { luma in
            let grid = luma.grid(columns: config.gridColumns, rows: config.gridRows)
            let energy = previousGrid.map { meanAbsoluteDifference($0, grid) } ?? 0
            previousGrid = grid
            lock.withLock {
                motion.append(MotionSample(t: time, energy: energy))
                if referenceRefreshPending { refreshPresentReferences(luma: luma) }
                adoptQueuedLocks(luma: luma)
                updatePresence(luma: luma, time: time)
                prune(now: time)
            }
        }

        maybeLocate(pixelBuffer, time: time)
        maybeSnapshot(time: time)
    }

    /// Everything observed between absolute times `start` and `end`, re-based
    /// to the recording start.
    func timeline(from start: Double, to end: Double) -> SceneTimeline {
        lock.withLock { SceneTimeline.slice(motion: motion, balls: tracks, from: start, to: end) }
    }

    /// Drops all history and locks (e.g. after the camera moved).
    func reset() {
        lock.withLock {
            motion = []
            tracks = []
            watched = []
            pending = []
            lockQueue = []
        }
        previousGrid = nil
    }

    var currentSnapshot: SceneSnapshot { lock.withLock { makeSnapshot() } }

    /// Re-takes the reference patch of every ball that is currently visible
    /// (on the next frame) — call after exposure changed.
    func refreshReferences() {
        lock.withLock { referenceRefreshPending = true }
    }

    private var visibleCount: Int { watched.filter { !$0.isGone }.count }

    // MARK: Ball locking

    private func maybeLocate(_ pixelBuffer: CVPixelBuffer, time: Double) {
        let shouldLocate: Bool = lock.withLock {
            guard !detectionInFlight, visibleCount < config.maxLocks,
                  time - lastLocateTime >= config.locateInterval else { return false }
            lastLocateTime = time
            detectionInFlight = true
            return true
        }
        guard shouldLocate else { return }

        if config.synchronousDetection {
            let found = locator.candidates(in: pixelBuffer)
            lock.withLock { mergeDetections(found, time: time) }
            return
        }
        // Detect on a private copy so the camera's buffer pool isn't starved
        // while the model runs.
        guard let copy = copier.copy(pixelBuffer) else {
            lock.withLock { detectionInFlight = false }
            return
        }
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let found = self.locator.candidates(in: copy)
            self.lock.withLock { self.mergeDetections(found, time: time) }
        }
    }

    /// A candidate seen at the same spot (within a quarter of its diameter)
    /// in `confirmations` consecutive passes is a stationary ball → queue it
    /// for locking (the reference patch is taken from the next ingested
    /// frame, on the ingest queue). Moving things — a hat, a shoe — never
    /// sit still long enough.
    private func mergeDetections(_ found: [BallCandidate], time: Double) {
        detectionInFlight = false
        var next: [PendingBall] = []
        var confirmed: [BallCandidate] = []
        for c in found {
            let alreadyWatched = watched.contains { w in
                let t = tracks[w.trackIndex]
                return !w.isGone && hypot(t.center.x - c.center.x, t.center.y - c.center.y) < CGFloat(max(t.diameterPx, c.diameterPx))
            }
            if alreadyWatched || next.contains(where: {
                hypot($0.candidate.center.x - c.center.x, $0.candidate.center.y - c.center.y) < CGFloat(c.diameterPx)
            }) { continue }
            let previous = pending.first { p in
                hypot(p.candidate.center.x - c.center.x, p.candidate.center.y - c.center.y)
                    < CGFloat(max(1.5, 0.25 * max(p.candidate.diameterPx, c.diameterPx)))
                    && (0.7...1.4).contains(c.diameterPx / max(p.candidate.diameterPx, 1))
            }
            var entry = PendingBall(candidate: c, sightings: 1)
            if let previous {
                entry.sightings = previous.sightings + 1
                entry.candidate = BallCandidate(
                    center: previous.candidate.center,
                    diameterPx: (previous.candidate.diameterPx * Double(previous.sightings) + c.diameterPx) / Double(entry.sightings),
                    confidence: max(previous.candidate.confidence, c.confidence))
            }
            if entry.sightings >= config.confirmations {
                confirmed.append(entry.candidate)
            } else {
                next.append(entry)
            }
        }
        pending = next
        let free = config.maxLocks - visibleCount - lockQueue.count
        for c in confirmed.prefix(max(0, free)) { lockQueue.append((c, time)) }
    }

    private func adoptQueuedLocks(luma: LumaImage) {
        guard !lockQueue.isEmpty else { return }
        for (c, time) in lockQueue {
            let radius = c.diameterPx * 0.32
            let reference = luma.disk(center: c.center, radius: radius)
            guard reference.count >= 9 else { continue }
            // A new ball where a gone one used to be: stop watching the old one.
            watched.removeAll { w in
                let t = tracks[w.trackIndex]
                return w.isGone && hypot(t.center.x - c.center.x, t.center.y - c.center.y) < CGFloat(max(t.diameterPx, c.diameterPx))
            }
            tracks.append(BallTrack(center: c.center, diameterPx: c.diameterPx,
                                    frameWidth: luma.width, frameHeight: luma.height,
                                    confidence: c.confidence, lockedAt: time))
            watched.append(WatchedBall(trackIndex: tracks.count - 1, reference: reference, radius: radius,
                                       presentSince: time))
        }
        lockQueue = []
    }

    /// Present / missing / gone / came back, per watched ball.
    private func updatePresence(luma: LumaImage, time: Double) {
        var forgotten: [Int] = []
        for i in watched.indices {
            let ball = watched[i]
            let center = tracks[ball.trackIndex].center
            let difference = meanAbsoluteDifference(ball.reference, luma.disk(center: center, radius: ball.radius))
            tracks[ball.trackIndex].presence.append(PresenceSample(t: time, difference: difference))
            if difference > config.absentThreshold {
                let since = ball.absentSince ?? time
                watched[i].absentSince = since
                watched[i].presentSince = nil
                if time - since >= config.goneAfter, !ball.isGone {
                    watched[i].isGone = true
                    tracks[ball.trackIndex].goneSince = since
                }
                if time - since >= config.forgetAfter { forgotten.append(i) }
            } else {
                let since = ball.presentSince ?? time
                watched[i].presentSince = since
                if ball.isGone {
                    if time - since >= config.returnAfter {
                        // It was only hidden (golfer, club, shadow).
                        watched[i].isGone = false
                        watched[i].absentSince = nil
                        tracks[ball.trackIndex].goneSince = nil
                    }
                } else {
                    watched[i].absentSince = nil
                }
            }
        }
        for i in forgotten.reversed() { watched.remove(at: i) }
    }

    private func refreshPresentReferences(luma: LumaImage) {
        referenceRefreshPending = false
        for i in watched.indices where watched[i].absentSince == nil {
            let reference = luma.disk(center: tracks[watched[i].trackIndex].center, radius: watched[i].radius)
            if reference.count == watched[i].reference.count { watched[i].reference = reference }
        }
    }

    private func forgetAllBalls() {
        watched = []
        lockQueue = []
        pending = []
    }

    private func prune(now: Double) {
        let cutoff = now - config.retention
        guard let first = motion.first, first.t < cutoff else { return }
        motion.removeAll { $0.t < cutoff }
        let keep = Set(watched.map(\.trackIndex))
        var remap: [Int: Int] = [:]
        var kept: [BallTrack] = []
        for (i, t) in tracks.enumerated() where keep.contains(i) || (t.presence.last?.t ?? now) >= cutoff {
            remap[i] = kept.count
            var copy = t
            copy.presence.removeAll { $0.t < cutoff }
            kept.append(copy)
        }
        tracks = kept
        watched = watched.compactMap { w in
            guard let j = remap[w.trackIndex] else { return nil }
            var copy = w
            copy.trackIndex = j
            return copy
        }
    }

    // MARK: Snapshots

    private func maybeSnapshot(time: Double) {
        guard let onSnapshot, time - lastSnapshotTime >= config.snapshotInterval else { return }
        lastSnapshotTime = time
        let snapshot = lock.withLock { makeSnapshot() }
        DispatchQueue.main.async { onSnapshot(snapshot) }
    }

    private func makeSnapshot() -> SceneSnapshot {
        let w = CGFloat(max(frameSize.width, 1)), h = CGFloat(max(frameSize.height, 1))
        let locks = watched.filter { !$0.isGone }.map { ball -> SceneSnapshot.Lock in
            let t = tracks[ball.trackIndex]
            return SceneSnapshot.Lock(id: t.id, center: CGPoint(x: t.center.x / w, y: t.center.y / h),
                                      diameter: CGFloat(t.diameterPx) / w, isPresent: ball.absentSince == nil)
        }
        let recent = motion.suffix(6).map(\.energy)
        let level = recent.isEmpty ? 0 : recent.reduce(0, +) / Float(recent.count)
        return SceneSnapshot(locks: locks, frameAspect: w / h, motionLevel: level)
    }
}

/// Copies camera pixel buffers into a private pool so they can be held while
/// a model runs without starving the capture pipeline.
final class PixelBufferCopier {
    private var pool: CVPixelBufferPool?
    private var poolKey: (OSType, Int, Int) = (0, 0, 0)

    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if pool == nil || poolKey != (format, width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                                    attrs as CFDictionary, &pool)
            poolKey = (format, width, height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let dest = out else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let s = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let d = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else { return nil }
                copyRows(from: s, to: d,
                         sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                         destStride: CVPixelBufferGetBytesPerRowOfPlane(dest, plane),
                         rows: CVPixelBufferGetHeightOfPlane(source, plane))
            }
        } else {
            guard let s = CVPixelBufferGetBaseAddress(source), let d = CVPixelBufferGetBaseAddress(dest) else { return nil }
            copyRows(from: s, to: d, sourceStride: CVPixelBufferGetBytesPerRow(source),
                     destStride: CVPixelBufferGetBytesPerRow(dest), rows: height)
        }
        return dest
    }

    private func copyRows(from s: UnsafeMutableRawPointer, to d: UnsafeMutableRawPointer,
                          sourceStride: Int, destStride: Int, rows: Int) {
        if sourceStride == destStride {
            memcpy(d, s, sourceStride * rows)
        } else {
            let n = min(sourceStride, destStride)
            for r in 0..<rows { memcpy(d + r * destStride, s + r * sourceStride, n) }
        }
    }
}
