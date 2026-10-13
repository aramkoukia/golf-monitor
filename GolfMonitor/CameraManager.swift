import AVFoundation
import UIKit

/// Owns the AVCaptureSession: picks the highest available frame rate
/// (preferring 240 fps slow-mo), streams preview frames, grabs single
/// calibration frames, and records short clips with AVAssetWriter.
final class CameraManager: NSObject, ObservableObject {

    // MARK: Published state

    @Published var isAuthorized = false
    @Published var isSessionRunning = false
    /// Frames per second actually selected (e.g. 240).
    @Published var selectedFPS: Double = 0
    @Published var selectedResolution: String = ""
    @Published var lastError: String?

    // MARK: Capture pipeline

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "golfmonitor.camera.session")
    private let videoQueue = DispatchQueue(label: "golfmonitor.camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?

    let previewLayer = AVCaptureVideoPreviewLayer()

    /// Called on videoQueue for every frame (preview / analysis).
    var frameHandler: ((CMSampleBuffer) -> Void)?
    /// One-shot: fires for the next frame, then clears itself.
    var singleFrameHandler: ((CMSampleBuffer) -> Void)?

    // MARK: Recording state (touched only on videoQueue)

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var recordStartPTS: CMTime?
    private var recordDuration: CMTime = .zero
    private var recordCompletion: ((URL?) -> Void)?
    private var recordURL: URL?

    // MARK: Permission & setup

    func requestPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSessionIfNeeded()
            DispatchQueue.main.async {
                self.isAuthorized = true
                // Tab switches stop the session (see stopSession); restart it
                // here. startSession is a no-op if already running, and the
                // onChange handler covers first-time authorization.
                self.startSession()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.isAuthorized = granted }
                if granted { self.setupSessionIfNeeded() }
            }
        default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.lastError = "Camera access is denied. Enable it in Settings → GolfMonitor → Camera."
            }
        }
    }

    private var didSetup = false

    private func setupSessionIfNeeded() {
        sessionQueue.async {
            guard !self.didSetup else { return }
            self.didSetup = true
            do {
                try self.configureSession()
                DispatchQueue.main.async { self.previewLayer.session = self.session }
            } catch {
                DispatchQueue.main.async { self.lastError = "Camera setup failed: \(error.localizedDescription)" }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraSetupError.noBackCamera
        }
        self.device = device

        // Pick the best slow-mo format before adding inputs.
        if let (format, fps) = Self.bestSlowMoFormat(for: device) {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            DispatchQueue.main.async {
                self.selectedFPS = fps
                self.selectedResolution = "\(dims.width)×\(dims.height)"
            }
        }

        // Focus: continuous autofocus is fine at the range; user can tap-lock later.
        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraSetupError.cannotAddInput }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraSetupError.cannotAddOutput }
        session.addOutput(videoOutput)
    }

    /// Picks the format with the best slow-motion capability: prefers 240 fps,
    /// falls back to the highest available >= 120 fps, resolution capped at 1080p.
    static func bestSlowMoFormat(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, Double)? {
        var bestFormat: AVCaptureDevice.Format?
        var bestFPS: Double = 0
        var bestScore: Double = -1

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 640, dims.width <= 1920 else { continue }
            for range in format.videoSupportedFrameRateRanges {
                let maxFPS = Double(range.maxFrameRate)
                guard maxFPS >= 120 else { continue }
                // Strongly prefer true 240 fps slow-mo; otherwise highest fps wins.
                let fpsScore: Double = maxFPS >= 230 ? 10_000 + maxFPS : maxFPS
                let resScore = Double(min(dims.width, 1920)) / 1920.0
                let score = fpsScore + resScore
                if score > bestScore {
                    bestScore = score
                    bestFormat = format
                    bestFPS = maxFPS >= 230 ? 240 : maxFPS
                }
            }
        }
        guard let format = bestFormat else { return nil }
        return (format, bestFPS)
    }

    // MARK: Session control

    func startSession() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = true
                self.updatePreviewOrientation()
            }
        }
    }

    func stopSession() {
        // Finish any in-flight recording first.
        videoQueue.async { self.finishRecording(completion: { _ in }) }
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Rotation angle that makes the image upright for the given device
    /// orientation. Angles are measured from the sensor's native landscape
    /// orientation (so portrait is 90°, not 0°).
    static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .portrait: return 90
        case .landscapeLeft: return 0       // home button on the right
        case .landscapeRight: return 180    // home button on the left
        case .portraitUpsideDown: return 270
        default: return nil // face up/down, unknown: leave as-is
        }
    }

    /// Rotates the preview layer — and the capture output feeding the
    /// recorder — to match how the phone is held. Called when the view
    /// appears, when the session starts, and on every device rotation.
    func updatePreviewOrientation() {
        DispatchQueue.main.async {
            guard let angle = Self.rotationAngle(for: UIDevice.current.orientation) else { return }
            // Preview layer: always follow.
            if let connection = self.previewLayer.connection,
               connection.isVideoRotationAngleSupported(angle),
               connection.videoRotationAngle != angle {
                connection.videoRotationAngle = angle
            }
            // Capture output: follow when not recording (a mid-clip change
            // would swap buffer dimensions mid-file).
            self.videoQueue.async {
                guard !self.isRecording,
                      let outConnection = self.videoOutput.connection(with: .video),
                      outConnection.isVideoRotationAngleSupported(angle),
                      outConnection.videoRotationAngle != angle else { return }
                outConnection.videoRotationAngle = angle
            }
        }
    }

    /// Locks focus & exposure at their current values (useful once the hitting
    /// zone is framed, so the camera doesn't hunt mid-swing).
    func lockFocusAndExposure() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.lastError = "Could not lock focus." }
        }
    }

    func unlockFocusAndExposure() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch { /* best effort */ }
    }

    /// Delivers the next preview frame to `completion` (for ball calibration).
    func captureSingleFrame(completion: @escaping (CMSampleBuffer) -> Void) {
        videoQueue.async { self.singleFrameHandler = completion }
    }

    // MARK: Clip recording

    /// Records a clip of `duration` seconds, then calls completion with the file URL.
    /// The completion is invoked on the main queue.
    func startRecording(duration: TimeInterval, completion: @escaping (URL?) -> Void) {
        videoQueue.async {
            guard !self.isRecording else { return }
            guard let device = self.device else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Pin the capture orientation to how the phone is held right now,
            // so the clip comes out upright (a rotation could otherwise land
            // after the last preview update).
            let angle = Self.rotationAngle(for: UIDevice.current.orientation) ?? 0
            if let outConnection = self.videoOutput.connection(with: .video),
               outConnection.isVideoRotationAngleSupported(angle) {
                outConnection.videoRotationAngle = angle
            }
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            // Buffers arrive pre-rotated: portrait angles swap width/height.
            let isPortraitAngle = (angle == 90 || angle == 270)
            let outWidth = isPortraitAngle ? Int(dims.height) : Int(dims.width)
            let outHeight = isPortraitAngle ? Int(dims.width) : Int(dims.height)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("shot-\(UUID().uuidString).mov")

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outWidth,
                AVVideoHeightKey: outHeight
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: nil
            )

            self.writer = writer
            self.writerInput = input
            self.adaptor = adaptor
            self.isRecording = true
            self.recordStartPTS = nil
            self.recordDuration = CMTime(seconds: duration, preferredTimescale: 600)
            self.recordCompletion = completion
            self.recordURL = url
        }
    }

    private func finishRecording(completion: ((URL?) -> Void)?) {
        guard isRecording else {
            if let completion { DispatchQueue.main.async { completion(nil) } }
            return
        }
        isRecording = false
        writerInput?.markAsFinished()
        let writer = self.writer
        let url = self.recordURL
        let completion = completion ?? self.recordCompletion
        self.recordCompletion = nil
        writer?.finishWriting {
            let ok = writer?.status == .completed
            DispatchQueue.main.async { completion?(ok ? url : nil) }
        }
        self.writer = nil
        self.writerInput = nil
        self.adaptor = nil
        self.recordStartPTS = nil
        self.recordURL = nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameHandler?(sampleBuffer)

        if let single = singleFrameHandler {
            singleFrameHandler = nil
            // Deliver off the video queue so calibration work doesn't block capture.
            DispatchQueue.global(qos: .userInitiated).async { single(sampleBuffer) }
        }

        guard isRecording,
              let writer, let writerInput, let adaptor,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if recordStartPTS == nil {
            recordStartPTS = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }
        guard let start = recordStartPTS else { return }
        let elapsed = CMTimeSubtract(pts, start)
        if CMTimeCompare(elapsed, recordDuration) >= 0 {
            finishRecording(completion: nil)
            return
        }
        if writer.status == .writing, writerInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        } else if writer.status == .failed {
            finishRecording(completion: nil)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Slow-mo at 240 fps may drop frames under load; the tracker tolerates gaps
        // because it uses per-frame presentation timestamps.
    }
}

enum CameraSetupError: Error {
    case noBackCamera
    case cannotAddInput
    case cannotAddOutput
}
