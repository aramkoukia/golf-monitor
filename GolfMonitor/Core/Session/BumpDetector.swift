import CoreMotion
import Foundation

/// Watches the accelerometer for significant device movement after the camera
/// has been calibrated (ball locked). A bump — a tripod knock, a wind gust,
/// or accidentally nudging the phone — invalidates the ball's measured pixel
/// size and shifts every distance and speed number derived from it.
///
/// Start watching just after a ball is locked; call `reset()` when the user
/// re-tees (new lock) or dismisses the result. Readings are advisory only;
/// recording is never blocked.
///
/// Must be created and used on the main actor.
@MainActor
final class BumpDetector: ObservableObject {

    // MARK: Configuration

    /// Gravity-subtracted acceleration magnitude (g) above which we consider
    /// the phone to have moved. 0.08 g ≈ a gentle nudge; tune upward if
    /// normal breathing/vibration triggers false positives.
    var threshold: Double = 0.08
    /// How long (s) the signal must exceed `threshold` before we report a
    /// bump. A single noisy sample is ignored; a real hit takes ≥ 2 frames.
    var durationRequired: TimeInterval = 0.05
    /// Minimum interval between successive bump events (debounce).
    var cooldown: TimeInterval = 3.0

    // MARK: Published state

    /// True after a bump was detected and until `reset()` is called.
    @Published private(set) var hasMoved = false

    // MARK: Private

    private let manager = CMMotionManager()
    private var watching = false
    private var gravity = CMAcceleration(x: 0, y: 0, z: -1)
    /// Timestamp when the signal first crossed the threshold in the current
    /// burst (nil when below threshold).
    private var burstStart: TimeInterval?
    private var lastBumpTime: TimeInterval = -.infinity
    /// How many gravity-settling samples to skip at start-up.
    private var settleCount = 0
    private static let settleFrames = 10   // ~0.2 s at 50 Hz

    // MARK: Public interface

    /// Begin monitoring. Safe to call when already watching (no-op).
    func startWatching() {
        guard !watching, manager.isAccelerometerAvailable else { return }
        watching = true
        hasMoved = false
        burstStart = nil
        settleCount = 0
        // 50 Hz is more than enough to catch a bump; keep CPU impact minimal.
        manager.accelerometerUpdateInterval = 1.0 / 50
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.handle(data)
        }
    }

    /// Stop monitoring without changing `hasMoved`. Call when recording
    /// starts (we no longer care about pre-shot bumps while recording).
    func stopWatching() {
        guard watching else { return }
        watching = false
        manager.stopAccelerometerUpdates()
    }

    /// Clear the moved flag and restart the baseline. Call when a new ball
    /// locks (new calibration baseline) or on `dismissResult`.
    func reset() {
        hasMoved = false
        burstStart = nil
        settleCount = 0
        gravity = CMAcceleration(x: 0, y: 0, z: -1)
        lastBumpTime = -.infinity
    }

    // MARK: Sample processing

    private func handle(_ data: CMAccelerometerData) {
        let a = data.acceleration

        // Let gravity settle over the first few frames so a just-placed phone
        // doesn't fire immediately.
        if settleCount < Self.settleFrames {
            settleCount += 1
            gravity = CMAcceleration(
                x: 0.8 * gravity.x + 0.2 * a.x,
                y: 0.8 * gravity.y + 0.2 * a.y,
                z: 0.8 * gravity.z + 0.2 * a.z)
            return
        }

        // Update a slow gravity estimate (LP filter, τ ≈ 1 s at 50 Hz).
        gravity = CMAcceleration(
            x: 0.98 * gravity.x + 0.02 * a.x,
            y: 0.98 * gravity.y + 0.02 * a.y,
            z: 0.98 * gravity.z + 0.02 * a.z)

        // Dynamic (gravity-subtracted) acceleration magnitude.
        let dx = a.x - gravity.x
        let dy = a.y - gravity.y
        let dz = a.z - gravity.z
        let magnitude = sqrt(dx * dx + dy * dy + dz * dz)
        let t = data.timestamp

        guard !hasMoved else { return }  // already fired; wait for reset()

        if magnitude >= threshold {
            if burstStart == nil { burstStart = t }
            if let start = burstStart, t - start >= durationRequired {
                // Check cooldown (burst fired too recently).
                if t - lastBumpTime >= cooldown {
                    lastBumpTime = t
                    hasMoved = true
                }
                burstStart = nil
            }
        } else {
            burstStart = nil
        }
    }
}
