import AVFoundation
import QuartzCore

/// Virtual camera for the Simulator (which has no camera): loops a bundled
/// CC0 240 fps range session — setup, a practice swing, the real strike —
/// at half speed as the "live" view, feeding its frames to the scene monitor
/// and the watch preview. "Recording" produces a copy of that session, which
/// then runs through the real on-device analysis pipeline.
final class SimulatedCaptureBackend: NSObject, CaptureBackend {
    var onStatus: ((CaptureStatus) -> Void)?
    var onFormat: ((CaptureFormat) -> Void)?
    var onExposureChange: (() -> Void)?
    var onCriticalPressure: (() -> Void)?
    var frameConsumers: [FrameConsumer] = []
    private(set) var format: CaptureFormat?
    var previewLayer: CALayer { playerLayer }

    private static let playbackRate: Float = 0.5
    private let clipURL: URL?
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var loopToken: NSObjectProtocol?
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ])
    private let frameQueue = DispatchQueue(label: "golfmonitor.capture.simulated", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var recordingStart: Double?

    deinit {
        if let loopToken { NotificationCenter.default.removeObserver(loopToken) }
    }

    init(clipName: String = "demo_session_faceon") {
        clipURL = Bundle.main.url(forResource: clipName, withExtension: "mp4")
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        player.isMuted = true
    }

    func start() {
        guard let clipURL else {
            onStatus?(.failed("Demo clip missing from the app bundle."))
            return
        }
        if player.currentItem == nil {
            let item = AVPlayerItem(url: clipURL)
            item.add(output)
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .none
            loopToken = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                               object: item, queue: .main) { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.rate = Self.playbackRate
            }
            format = CaptureFormat(fps: 240, width: 720, height: 1280, fieldOfView: 63, isSimulated: true)
            if let format { onFormat?(format) }
        }
        player.rate = Self.playbackRate
        startFrameTimer()
        onStatus?(.running)
    }

    func stop() {
        player.pause()
        timer?.cancel()
        timer = nil
        onStatus?(.idle)
    }

    func setShutter(_ seconds: Double?) {}

    func startRecording(to url: URL) throws {
        guard clipURL != nil else { throw CaptureError.notRunning }
        recordingStart = CACurrentMediaTime()
    }

    func stopRecording(_ completion: @escaping (Result<RecordedVideo, Error>) -> Void) {
        guard let start = recordingStart, let clipURL else {
            completion(.failure(CaptureError.notRecording))
            return
        }
        recordingStart = nil
        let end = CACurrentMediaTime()
        Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).mp4")
            do {
                try FileManager.default.copyItem(at: clipURL, to: url)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                completion(.success(RecordedVideo(url: url, duration: duration, fps: 240,
                                                  startTime: start, endTime: end, hasLiveTimeline: false)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancelRecording() { recordingStart = nil }

    // MARK: Frames

    private func startFrameTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in self?.pullFrame() }
        timer.resume()
        self.timer = timer
    }

    private func pullFrame() {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        let time = CACurrentMediaTime()
        for consumer in frameConsumers { consumer.consume(buffer, time: time) }
    }
}
