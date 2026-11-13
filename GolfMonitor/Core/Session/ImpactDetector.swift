import AVFoundation
import Foundation

/// Listens on the microphone for the sharp transient of a golf ball impact
/// and fires `onImpact` once per recording session. Used to auto-stop the
/// recording about 2 seconds after the crack so the user never has to press
/// Stop.
///
/// Detection strategy:
///  1. Tap the input node's output (mono, 44.1 kHz) with a small buffer.
///  2. Compute the peak absolute sample value of each buffer.
///  3. Maintain a short-term max (the loudest recent frame) and a medium-term
///     background level to establish a dynamic "quiet floor."
///  4. Fire when the peak rises sharply above the background — specifically
///     when it exceeds `backgroundMultiplier × background` and also crosses
///     an absolute minimum floor, so wind and rustling don't trigger.
///  5. After firing, ignore audio for `cooldown` seconds (debounce: one
///     crack, one event, even on metallic resonance).
///
/// Must be created and used on the main actor; the audio tap dispatches the
/// callback to the main queue.
@MainActor
final class ImpactDetector {

    // MARK: - Configuration

    /// A sample peak must exceed `backgroundMultiplier × background` to fire.
    /// 4× means roughly +12 dB above the room noise floor. Tune down if
    /// real impacts are frequently missed; tune up if wind/voices trigger it.
    var backgroundMultiplier: Float = 4.0

    /// Absolute minimum peak (0…1 linear) to ever fire, regardless of
    /// background. Prevents firing in total silence from digital noise.
    var absoluteFloor: Float = 0.05

    /// How fast the background level tracker rises with louder signals (0…1).
    /// Slower = more immune to gradual noise creep; faster = adapts sooner.
    var backgroundAttack: Float = 0.02

    /// How fast the background level tracker falls toward quieter levels.
    var backgroundDecay: Float = 0.001

    /// Seconds after firing during which further detections are ignored.
    var cooldown: TimeInterval = 3.0

    /// How long (seconds) after the impact cue to auto-stop the recording.
    /// 2 s gives the camera `ShotFinder.postRoll (1.4 s)` of ball-flight data
    /// plus some margin.
    var autoStopDelay: TimeInterval = 2.0

    // MARK: - Callbacks

    /// Called on the main actor when an impact is detected.
    /// Provides the host-time timestamp of the detection.
    var onImpact: (() -> Void)?

    // MARK: - State

    private(set) var isListening = false

    // MARK: - Private

    private let engine = AVAudioEngine()
    private var background: Float = 0.01
    private var lastFiredAt: Date?

    // MARK: - Public interface

    /// Start listening. Activates `AVAudioSession` for recording, then
    /// installs an audio tap on the input node.
    /// Safe to call when already listening (no-op).
    func startListening() {
        guard !isListening else { return }

        // Configure the audio session for recording. Use .playAndRecord so a
        // future ShotAnnouncer (.playback) can interrupt cleanly after we stop.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
            // Microphone permission may have been denied; fail silently — the
            // detector is an optional convenience, not required for recording.
            return
        }

        // Reset state so a new recording starts with a fresh baseline.
        background = 0.01
        lastFiredAt = nil

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Guard against unusual formats (Simulator returns a no-channel format).
        guard format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let peak = Self.peak(of: buffer)
            DispatchQueue.main.async { self.process(peak: peak) }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        isListening = true
    }

    /// Stop listening. Removes the tap and deactivates the audio session.
    /// Safe to call when not listening (no-op).
    func stopListening() {
        guard isListening else { return }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Signal processing (main actor)

    private func process(peak: Float) {
        // Update the slow-moving background estimate.
        if peak > background {
            background = background + backgroundAttack * (peak - background)
        } else {
            background = background - backgroundDecay * (background - peak)
        }

        // Check if this buffer looks like an impact.
        guard peak >= absoluteFloor else { return }
        guard peak >= background * backgroundMultiplier else { return }

        // Debounce.
        let now = Date()
        if let last = lastFiredAt, now.timeIntervalSince(last) < cooldown { return }

        lastFiredAt = now
        onImpact?()
    }

    // MARK: - Utility

    /// Peak absolute sample value across all channels in `buffer` (0…1).
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = data[channel]
            for i in 0..<frameCount {
                let v = abs(samples[i])
                if v > peak { peak = v }
            }
        }
        return peak
    }
}
