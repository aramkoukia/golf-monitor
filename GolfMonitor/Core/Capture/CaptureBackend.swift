import AVFoundation
import QuartzCore

/// Camera status shown in the UI.
enum CaptureStatus: Equatable {
    case idle
    case starting
    case running
    /// Camera permission denied or restricted.
    case denied
    /// Another app or a phone call took the camera.
    case interrupted
    case failed(String)

    var isLive: Bool { self == .running }
}

/// The capture format actually in use.
struct CaptureFormat: Equatable {
    var fps: Double
    var width: Int
    var height: Int
    /// Horizontal field of view in degrees (for distance estimates).
    var fieldOfView: Double
    var isSimulated = false

    /// "240 FPS · 1080P"
    var badge: String {
        let lines = min(width, height)
        return "\(Int(fps.rounded())) FPS · \(lines)P\(isSimulated ? " · DEMO" : "")"
    }
}

/// A finished recording file and its time base.
struct RecordedVideo {
    var url: URL
    var duration: Double
    var fps: Double
    /// Capture clock times (seconds) of the first and last written frames —
    /// the same clock the frame consumers see, so the scene monitor's
    /// timeline can be sliced to exactly this recording.
    var startTime: Double
    var endTime: Double
    /// False when the file isn't what the frame consumers saw (the
    /// Simulator's virtual camera): the timeline must be scanned from the file.
    var hasLiveTimeline: Bool = true
}

/// Receives camera frames on the capture queue. Must return quickly.
protocol FrameConsumer: AnyObject {
    func consume(_ pixelBuffer: CVPixelBuffer, time: Double)
}

/// A camera implementation: the real one on device, a looping demo clip in
/// the Simulator. Callbacks may arrive on any queue.
protocol CaptureBackend: AnyObject {
    var previewLayer: CALayer { get }
    var format: CaptureFormat? { get }
    var onStatus: ((CaptureStatus) -> Void)? { get set }
    var onFormat: ((CaptureFormat) -> Void)? { get set }
    /// Called when exposure changes the look of the scene (scene monitor
    /// re-takes its reference patches).
    var onExposureChange: (() -> Void)? { get set }
    /// Called (any queue) when the device is too hot to keep recording.
    var onCriticalPressure: (() -> Void)? { get set }
    var frameConsumers: [FrameConsumer] { get set }

    func start()
    func stop()
    /// Fast shutter for sharp ball/club frames (nil = auto exposure).
    func setShutter(_ seconds: Double?)
    func startRecording(to url: URL) throws
    func stopRecording(_ completion: @escaping (Result<RecordedVideo, Error>) -> Void)
    func cancelRecording()
}
