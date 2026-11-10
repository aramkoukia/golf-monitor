import AVFoundation

/// Writes camera sample buffers to a .mov in real time. Created per
/// recording; the writer is configured lazily from the first frame so the
/// file always matches the (already rotated) buffer dimensions.
///
/// Confined to the capture queue that delivers frames.
final class VideoFileRecorder {
    enum RecorderError: LocalizedError {
        case noFrames
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "No video frames were recorded."
            case .writerFailed(let reason): return reason
            }
        }
    }

    let url: URL
    private let fps: Double
    private let baseSettings: [String: Any]
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private(set) var failure: String?
    private(set) var framesWritten = 0

    /// - Parameter settings: output settings without dimensions (codec,
    ///   bitrate…); width/height are taken from the first frame.
    init(url: URL, fps: Double, settings: [String: Any]) {
        self.url = url
        self.fps = fps
        self.baseSettings = settings
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard failure == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard start(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), at: pts) else { return }
        }
        guard let writer, let input else { return }
        if writer.status == .failed {
            failure = writer.error?.localizedDescription ?? "The video writer failed."
            return
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            framesWritten += 1
            lastPTS = pts
        }
    }

    func finish(_ completion: @escaping (Result<RecordedVideo, Error>) -> Void) {
        // Finishing a writer that isn't `.writing` raises an Objective-C
        // exception, so a failed writer is cancelled instead.
        guard failure == nil, let writer, let input, writer.status == .writing,
              let first = firstPTS, let last = lastPTS, framesWritten > 0 else {
            let reason = failure ?? self.writer?.error?.localizedDescription
            self.writer?.cancelWriting()
            self.writer = nil
            self.input = nil
            try? FileManager.default.removeItem(at: url)
            completion(.failure(reason.map(RecorderError.writerFailed) ?? RecorderError.noFrames))
            return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: last)
        let url = self.url, fps = self.fps
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(RecordedVideo(url: url, duration: (last - first).seconds, fps: fps,
                                                  startTime: first.seconds, endTime: last.seconds)))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(RecorderError.writerFailed(writer.error?.localizedDescription ?? "The recording couldn't be finished.")))
            }
        }
        self.writer = nil
        self.input = nil
    }

    func cancel() {
        writer?.cancelWriting()
        writer = nil
        input = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func start(width: Int, height: Int, at pts: CMTime) -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            var settings = baseSettings
            settings[AVVideoWidthKey] = width
            settings[AVVideoHeightKey] = height
            var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded())
            // Frequent keyframes keep shot clips cut without re-encoding accurate.
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 0.5
            settings[AVVideoCompressionPropertiesKey] = compression
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                failure = "The recording format isn't supported."
                return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                failure = writer.error?.localizedDescription ?? "The video writer couldn't start."
                return false
            }
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            self.input = input
            firstPTS = pts
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}
