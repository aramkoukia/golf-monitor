import AVFoundation
import UIKit

/// The real camera: back wide lens at the best slow-motion format (240 fps
/// preferred), bi-planar 420f buffers (the Y plane doubles as luma for the
/// scene monitor), HEVC recording, fast shutter with automatic ISO while
/// idle, focus/exposure/white balance locked while recording, upright
/// buffers via `AVCaptureDevice.RotationCoordinator`.
final class DeviceCaptureBackend: NSObject, CaptureBackend {
    var onStatus: ((CaptureStatus) -> Void)?
    var onFormat: ((CaptureFormat) -> Void)?
    var onExposureChange: (() -> Void)?
    var onCriticalPressure: (() -> Void)?
    /// Set before `start()`; read on the video queue.
    var frameConsumers: [FrameConsumer] = []

    private(set) var format: CaptureFormat?
    var previewLayer: CALayer { preview }

    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "golfmonitor.capture.session")
    private let videoQueue = DispatchQueue(label: "golfmonitor.capture.video", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []        // session queue
    private var rotationObservations: [NSKeyValueObservation] = [] // main queue
    private var captureRotationAngle: CGFloat?                     // video queue
    private var notificationTokens: [NSObjectProtocol] = []

    // Exposure (session queue).
    private var shutterSeconds: Double?
    private var exposureTimer: DispatchSourceTimer?

    // Recording (video queue).
    private var recorder: VideoFileRecorder?
    private var isRecording = false

    override init() {
        super.init()
        preview.videoGravity = .resizeAspectFill
        observeSessionNotifications()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Lifecycle

    func start() {
        onStatus?(.starting)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.sessionQueue.async { self.configureAndRun() } } else { self.onStatus?(.denied) }
            }
        default:
            onStatus?(.denied)
        }
    }

    func stop() {
        sessionQueue.async {
            self.exposureTimer?.cancel()
            self.exposureTimer = nil
            if self.session.isRunning { self.session.stopRunning() }
            self.onStatus?(.idle)
        }
    }

    private func configureAndRun() {
        if !isConfigured {
            do {
                try configure()
                isConfigured = true
            } catch {
                // Leave the session empty so a retry starts from scratch.
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                session.commitConfiguration()
                onStatus?(.failed(error.localizedDescription))
                return
            }
        }
        if !session.isRunning { session.startRunning() }
        applyExposure()
        startExposureLoop()
        onStatus?(session.isRunning ? .running : .failed("The camera didn't start."))
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        self.device = device
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotUseCamera }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotUseCamera }
        session.addOutput(videoOutput)

        guard let pick = SlowMotionFormatPicker.best(for: device) else { throw CaptureError.noSlowMotion }
        try device.lockForConfiguration()
        device.activeFormat = pick.format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(pick.fps.rounded()))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
        if pick.format.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()

        if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        let dims = CMVideoFormatDescriptionGetDimensions(pick.format.formatDescription)
        let format = CaptureFormat(fps: pick.fps, width: Int(dims.width), height: Int(dims.height),
                                   fieldOfView: Double(pick.format.videoFieldOfView))
        self.format = format
        onFormat?(format)

        observations.append(device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            if device.systemPressureState.level == .critical || device.systemPressureState.level == .shutdown {
                self?.onCriticalPressure?()
            }
        })

        DispatchQueue.main.async {
            self.preview.session = self.session
            self.setUpRotation(for: device)
        }
    }

    // MARK: Rotation

    private func setUpRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        })
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] c, _ in
            self?.applyCaptureRotation(c.videoRotationAngleForHorizonLevelCapture)
        })
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Buffers are rotated upright before they reach the recorder and the
    /// scene monitor, so files have no transform and coordinates agree.
    /// Never changed mid-recording (it would change the frame size).
    private func applyCaptureRotation(_ angle: CGFloat) {
        videoQueue.async {
            self.captureRotationAngle = angle
            guard !self.isRecording, let connection = self.videoOutput.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }
    }

    // MARK: Exposure

    func setShutter(_ seconds: Double?) {
        sessionQueue.async {
            self.shutterSeconds = seconds
            self.applyExposure()
        }
    }

    /// Custom exposure at the requested shutter with ISO matched to the
    /// current brightness, or continuous auto exposure.
    private func applyExposure() {
        guard let device, isConfigured else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let format = device.activeFormat
            if let seconds = shutterSeconds, device.isExposureModeSupported(.custom) {
                let wanted = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
                let duration = CMTimeClampToRange(wanted, range: CMTimeRange(start: format.minExposureDuration,
                                                                              end: format.maxExposureDuration))
                let currentSeconds = max(device.exposureDuration.seconds, 1e-6)
                let scaled = device.iso * Float(currentSeconds / duration.seconds)
                let iso = min(max(scaled, format.minISO), format.maxISO)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            return
        }
        onExposureChange?()
    }

    /// While idle, nudges ISO toward a correct exposure (the shutter stays
    /// fixed). Paused while recording so frames stay consistent.
    private func startExposureLoop() {
        exposureTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.adjustISO() }
        timer.resume()
        exposureTimer = timer
    }

    private func adjustISO() {
        guard let device, shutterSeconds != nil, device.exposureMode == .custom else { return }
        let recording = videoQueue.sync { isRecording }
        guard !recording else { return }
        let offset = device.exposureTargetOffset
        guard offset.isFinite, abs(offset) > 0.35 else { return }
        let format = device.activeFormat
        let iso = min(max(device.iso * powf(2, -offset), format.minISO), format.maxISO)
        guard abs(iso - device.iso) > 1 else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: iso, completionHandler: nil)
            device.unlockForConfiguration()
            onExposureChange?()
        } catch {}
    }

    private func setCaptureLocked(_ locked: Bool) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if locked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if shutterSeconds == nil, device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if shutterSeconds == nil, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        } catch {}
    }

    // MARK: Recording

    func startRecording(to url: URL) throws {
        guard session.isRunning, let format else { throw CaptureError.notRunning }
        let codecs = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        let codec: AVVideoCodecType = codecs.contains(.hevc) ? .hevc : .h264
        var settings = videoOutput.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: .mov) ?? [:]
        settings[AVVideoCodecKey] = codec
        let recorder = VideoFileRecorder(url: url, fps: format.fps, settings: settings)
        sessionQueue.async { self.setCaptureLocked(true) }
        videoQueue.sync {
            self.recorder = recorder
            self.isRecording = true
        }
    }

    func stopRecording(_ completion: @escaping (Result<RecordedVideo, Error>) -> Void) {
        videoQueue.async {
            guard let recorder = self.recorder else {
                completion(.failure(CaptureError.notRecording))
                return
            }
            self.recorder = nil
            self.isRecording = false
            recorder.finish(completion)
            self.sessionQueue.async { self.setCaptureLocked(false) }
            // Catch up with any rotation that happened while recording.
            if let angle = self.captureRotationAngle { self.applyCaptureRotation(angle) }
        }
    }

    func cancelRecording() {
        videoQueue.async {
            self.recorder?.cancel()
            self.recorder = nil
            self.isRecording = false
            self.sessionQueue.async { self.setCaptureLocked(false) }
        }
    }

    // MARK: Interruptions

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                     object: session, queue: nil) { [weak self] _ in
            self?.onStatus?(.interrupted)
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                     object: session, queue: nil) { [weak self] _ in
            self?.onStatus?(.running)
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                     object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset {
                self.sessionQueue.async { self.configureAndRun() }
            } else {
                self.onStatus?(.failed(error?.localizedDescription ?? "The camera stopped unexpectedly."))
            }
        })
    }
}

extension DeviceCaptureBackend: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        recorder?.append(sampleBuffer)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        for consumer in frameConsumers { consumer.consume(pixelBuffer, time: time) }
    }
}

enum CaptureError: LocalizedError {
    case noCamera, cannotUseCamera, noSlowMotion, notRunning, notRecording

    var errorDescription: String? {
        switch self {
        case .noCamera: return "This device has no back camera."
        case .cannotUseCamera: return "The camera couldn't be configured."
        case .noSlowMotion: return "This camera doesn't support slow-motion (120 fps or faster)."
        case .notRunning: return "The camera isn't running."
        case .notRecording: return "Nothing is being recorded."
        }
    }
}

/// Picks the best slow-motion format: 240 fps preferred over 120, then the
/// highest resolution up to 1080p, then full-range 420f buffers.
enum SlowMotionFormatPicker {
    struct Pick {
        var format: AVCaptureDevice.Format
        var fps: Double
    }

    static func best(for device: AVCaptureDevice) -> Pick? {
        var best: (pick: Pick, score: Double)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let lines = Double(min(dims.width, dims.height))
            guard lines >= 720, lines <= 1080 else { continue }
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS >= 119 else { continue }
            let fps = maxFPS >= 239 ? 240.0 : min(maxFPS, 240)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let fullRange = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let score = score(fps: fps, lines: lines, fullRange: fullRange)
            if best == nil || score > best!.score { best = (Pick(format: format, fps: fps), score) }
        }
        return best?.pick
    }

    static func score(fps: Double, lines: Double, fullRange: Bool) -> Double {
        (fps >= 239 ? 10_000 : fps * 10) + lines + (fullRange ? 1 : 0)
    }
}
