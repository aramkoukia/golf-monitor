import AVFoundation
import Photos
import CoreVideo
import Foundation

enum SessionVideoProcessor {
    struct ShotRange: Sendable {
        let start: Double
        let duration: Double
    }

    static func detectShotRanges(in url: URL) async throws -> [ShotRange] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SessionVideoError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SessionVideoError.cannotReadVideo }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SessionVideoError.cannotReadVideo
        }

        var previousPixels: [UInt8]?
        var frameIndex = 0
        var lastTrigger = -3.0
        var triggers: [Double] = []

        while let sample = output.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard frameIndex.isMultiple(of: 4),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                  pts.isFinite
            else { continue }

            guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                continue
            }
            let currentPixels = sampledLuma(from: pixelBuffer)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

            if let previousPixels, previousPixels.count == currentPixels.count {
                let changed = zip(previousPixels, currentPixels).reduce(into: 0) { count, pair in
                    if abs(Int(pair.0) - Int(pair.1)) >= 32 { count += 1 }
                }
                let changedFraction = Double(changed) / Double(currentPixels.count)
                if changedFraction >= 0.045, pts - lastTrigger >= 2.5 {
                    triggers.append(pts)
                    lastTrigger = pts
                }
            }
            previousPixels = currentPixels
        }

        guard reader.status == .completed else {
            throw reader.error ?? SessionVideoError.cannotReadVideo
        }

        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SessionVideoError.invalidDuration }
        let ranges = triggers.map { trigger in
            let start = max(0, trigger - 0.8)
            let end = min(duration, trigger + 2.2)
            return ShotRange(start: start, duration: max(0, end - start))
        }
        .filter { $0.duration >= 1.5 }
        return ranges.reduce(into: [ShotRange]()) { merged, range in
            guard let previous = merged.last else {
                merged.append(range)
                return
            }
            let previousEnd = previous.start + previous.duration
            if range.start <= previousEnd {
                merged[merged.count - 1] = ShotRange(
                    start: previous.start,
                    duration: max(previousEnd, range.start + range.duration) - previous.start
                )
            } else {
                merged.append(range)
            }
        }
    }

    private static func sampledLuma(from pixelBuffer: CVPixelBuffer) -> [UInt8] {
        let columns = 32
        let rows = 24
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)?
            .assumingMemoryBound(to: UInt8.self) else { return [] }

        var values: [UInt8] = []
        values.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = height / 8 + row * (height * 3 / 4) / rows
            for column in 0..<columns {
                let x = width / 8 + column * (width * 3 / 4) / columns
                let offset = y * bytesPerRow + x * 4
                let blue = Int(baseAddress[offset])
                let green = Int(baseAddress[offset + 1])
                let red = Int(baseAddress[offset + 2])
                values.append(UInt8((red * 3 + green * 6 + blue) / 10))
            }
        }
        return values
    }

    static func exportClip(from url: URL, range: ShotRange) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw SessionVideoError.cannotExportClip
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-shot-\(UUID().uuidString).mov")
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            duration: CMTime(seconds: range.duration, preferredTimescale: 600)
        )
        exporter.shouldOptimizeForNetworkUse = false

        try await exporter.export(to: outputURL, as: .mov)
        return outputURL
    }
}

enum PhotoLibraryExporter {
    static func saveVideo(at url: URL) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw SessionVideoError.photoLibraryAccessDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? SessionVideoError.photoLibrarySaveFailed)
                }
            }
        }
    }
}

enum SessionVideoError: LocalizedError {
    case noVideoTrack
    case cannotReadVideo
    case invalidDuration
    case cannotExportClip
    case photoLibraryAccessDenied
    case photoLibrarySaveFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The session recording contains no video track."
        case .cannotReadVideo: "The session recording could not be scanned for shots."
        case .invalidDuration: "The session recording has an invalid duration."
        case .cannotExportClip: "A shot clip could not be created from the session video."
        case .photoLibraryAccessDenied: "Allow GolfMonitor to add videos in Photos settings, then try again."
        case .photoLibrarySaveFailed: "The session video could not be saved to Photos."
        }
    }
}
