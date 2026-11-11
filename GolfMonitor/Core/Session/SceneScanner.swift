import AVFoundation
import Foundation

/// Runs `SceneMonitor` over a video file instead of live camera frames —
/// for the Simulator's virtual camera, imported videos and tests. Same
/// algorithm, so offline results match what the live monitor would see.
enum SceneScanner {
    static func scan(url: URL, locator: BallLocating = GolfBallLocator(),
                     progress: ((Double) -> Void)? = nil) async throws -> SceneTimeline {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SessionError.unreadableRecording
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SessionError.unreadableRecording }

        return try await Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw SessionError.unreadableRecording }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? SessionError.unreadableRecording }

            var config = SceneMonitor.Config()
            config.synchronousDetection = true
            config.locateInterval = 0.25
            let monitor = SceneMonitor(config: config, locator: locator)
            var firstPTS: Double?
            var lastTime = 0.0
            var lastReported = -1.0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard pts.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                if firstPTS == nil { firstPTS = pts }
                let t = pts - (firstPTS ?? pts)
                lastTime = t
                monitor.ingest(buffer, time: t)
                if let progress, t - lastReported >= 0.25 {
                    lastReported = t
                    progress(min(1, t / duration))
                }
            }
            if reader.status == .failed { throw reader.error ?? SessionError.unreadableRecording }
            let end = max(lastTime + 1.0 / 240, duration)
            return monitor.timeline(from: 0, to: end)
        }.value
    }
}

/// Cuts a time range out of a recording without re-encoding.
enum ClipExporter {
    static func export(from url: URL, start: Double, end: Double, to destination: URL? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SessionError.clipExportFailed
        }
        let out = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: out)
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 6000),
                                         end: CMTime(seconds: max(start, end), preferredTimescale: 6000))
        exporter.shouldOptimizeForNetworkUse = false
        do {
            try await exporter.export(to: out, as: .mov)
        } catch {
            throw SessionError.clipExportFailed
        }
        return out
    }
}

enum SessionError: LocalizedError, Equatable {
    case unreadableRecording
    case noMotionFound
    case clipExportFailed
    case cameraNotReady
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableRecording: return "The recording couldn't be read."
        case .noMotionFound: return "No swing was found in the recording. Keep the whole swing in frame, and stand still for a moment before and after you swing."
        case .clipExportFailed: return "The shot clip couldn't be cut from the recording."
        case .cameraNotReady: return "The camera isn't ready yet."
        case .recordingFailed(let reason): return "Recording failed: \(reason)"
        }
    }
}
