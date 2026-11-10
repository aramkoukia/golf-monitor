import CoreVideo
import Foundation
import Combine
import QuartzCore

/// What the range session needs from a camera (faked in tests).
@MainActor
protocol RecordingDevice: AnyObject {
    var isReadyToRecord: Bool { get }
    var frameRate: Double { get }
    func startRecording() throws
    func stopRecording() async throws -> RecordedVideo
    func cancelRecording()
}

/// App-lifetime owner of the camera. Lives above the tab bar so the watch
/// can start a recording whatever screen the phone is showing (the phone
/// then switches to the Range tab so you can see it recording).
@MainActor
final class CameraController: ObservableObject, RecordingDevice {
    @Published private(set) var status: CaptureStatus = .idle
    @Published private(set) var format: CaptureFormat?
    @Published private(set) var isRecording = false

    private let backend: CaptureBackend
    var onCriticalPressure: (() -> Void)?
    var onExposureChange: (() -> Void)?
    /// Minimum free space required to start a recording.
    var minimumFreeBytes: Int64 = 1_000_000_000

    var previewLayer: CALayer { backend.previewLayer }
    var isSimulated: Bool { backend is SimulatedCaptureBackend }

    init(backend: CaptureBackend? = nil, consumers: [FrameConsumer] = []) {
        self.backend = backend ?? Self.makeDefaultBackend()
        self.backend.frameConsumers = consumers
        self.backend.onStatus = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        self.backend.onFormat = { [weak self] format in
            Task { @MainActor in self?.format = format }
        }
        self.backend.onExposureChange = { [weak self] in
            Task { @MainActor in self?.onExposureChange?() }
        }
        self.backend.onCriticalPressure = { [weak self] in
            Task { @MainActor in self?.onCriticalPressure?() }
        }
    }

    static func makeDefaultBackend() -> CaptureBackend {
        #if targetEnvironment(simulator)
        return SimulatedCaptureBackend()
        #else
        return DeviceCaptureBackend()
        #endif
    }

    func start() {
        guard status != .running, status != .starting else { return }
        status = .starting
        backend.start()
    }

    func stop() {
        guard !isRecording else { return }
        backend.stop()
    }

    func setShutter(_ seconds: Double?) { backend.setShutter(seconds) }

    // MARK: RecordingDevice

    var isReadyToRecord: Bool { status.isLive && !isRecording }
    var frameRate: Double { format?.fps ?? 240 }

    func startRecording() throws {
        guard status.isLive else { throw SessionError.cameraNotReady }
        guard !isRecording else { return }
        if let free = Self.freeDiskBytes(), free < minimumFreeBytes {
            throw SessionError.recordingFailed("less than 1 GB of free space — free some storage first")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).mov")
        try backend.startRecording(to: url)
        isRecording = true
    }

    func stopRecording() async throws -> RecordedVideo {
        guard isRecording else { throw CaptureError.notRecording }
        defer { isRecording = false }
        return try await withCheckedThrowingContinuation { continuation in
            backend.stopRecording { continuation.resume(with: $0) }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        backend.cancelRecording()
        isRecording = false
    }

    private static func freeDiskBytes() -> Int64? {
        let url = FileManager.default.temporaryDirectory
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

extension SceneMonitor: FrameConsumer {
    func consume(_ pixelBuffer: CVPixelBuffer, time: Double) { ingest(pixelBuffer, time: time) }
}
