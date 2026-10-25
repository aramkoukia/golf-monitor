import AVFoundation
import CoreGraphics
import CoreImage
import CoreML
import Vision

// MARK: - Result types

struct TrackedPoint {
    /// Pixel coordinates, origin top-left.
    var x: Double
    var y: Double
    /// Seconds since first frame.
    var time: Double
}

struct TrackingResult {
    var ballPoints: [TrackedPoint] = []
    /// Index into ballPoints of the impact frame (first frame of ball motion).
    var impactBallIndex: Int?
    /// Clubhead centroids, pre-impact only.
    var clubPoints: [TrackedPoint] = []
    /// Takeaway-start and top-of-backswing frame indices (into clubPoints).
    var takeawayIndex: Int?
    var topOfSwingIndex: Int?
    var fps: Double = 240
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var ballFound: Bool = false
}

/// One detected ball in a single frame (calibration).
struct DetectedBall {
    /// Ball center in frame pixels (same space as frameWidth/frameHeight).
    var center: CGPoint
    /// Estimated ball diameter in pixels.
    var diameter: Double
    var frameWidth: Int
    var frameHeight: Int
}

struct BallDetectionOutcome {
    var ball: DetectedBall?
    var failureReason: String?
}

// MARK: - Tracking engine

/// Frame-by-frame analysis of a recorded swing clip.
///
/// Strategy (side-view camera):
/// 1. Frame 0: find the stationary ball as a bright, ball-sized blob.
/// 2. Every frame: re-find the ball in a small ROI around its last position.
///    Impact = the first frame where the ball jumps more than ~1.2 ball diameters.
/// 3. Pre-impact: the clubhead is the largest moving blob (frame differencing)
///    in the lower part of the frame.
/// 4. Tempo: takeaway start = first sustained club motion; top = highest
///    clubhead point before impact.
///
/// All processing is offline (after the clip is recorded) on a background queue.
/// Note: grayscale frames are stored at HALF resolution (every 2nd pixel).
/// Calibration and tracking both live in this space, so the pixel→meter scale
/// stays consistent throughout.
final class TrackingEngine {

    // MARK: Tunables

    /// Grayscale level above which a pixel counts as "ball white".
    private let brightThreshold: UInt8 = 205
    /// Grayscale difference above which a pixel counts as "moving".
    private let motionThreshold: UInt8 = 28
    /// Pixel stride for blob scans (2 = check every 2nd pixel; ~4x faster).
    private let scanStride = 2

    // MARK: Entry point

    /// Tracks ball + clubhead through the clip at `videoURL`.
    /// - Parameters:
    ///   - videoURL: recorded .mov clip.
    ///   - fps: capture frame rate (used for time base).
    ///   - expectedBallDiameterPx: from calibration; guides blob size filtering.
    func track(videoURL: URL, fps: Double, expectedBallDiameterPx: Double?) -> TrackingResult {
        var result = TrackingResult(fps: fps)

        let asset = AVAsset(url: videoURL)
        // tracks(withMediaType:) is deprecated since iOS 16 — load the tracks
        // asynchronously and bridge back synchronously. This method already
        // runs on a background queue, so the semaphore can't deadlock the UI.
        let videoTracks: [AVAssetTrack] = {
            var loaded: [AVAssetTrack] = []
            let sem = DispatchSemaphore(value: 0)
            Task {
                loaded = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                sem.signal()
            }
            sem.wait()
            return loaded
        }()
        guard let track = videoTracks.first,
              let reader = try? AVAssetReader(asset: asset)
        else { return result }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading() else { return result }

        let ballDiameterPx = expectedBallDiameterPx ?? 24
        let ballArea = Double.pi * pow(ballDiameterPx / 2.0, 2)

        var prevGray: GrayImage?
        var firstPTS: CMTime?
        var ballPos: CGPoint?
        var impactFound = false

        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstPTS == nil { firstPTS = pts }
            let t = CMTimeSubtract(pts, firstPTS ?? pts).seconds
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                  let gray = GrayImage(from: pixelBuffer)
            else { continue }

            let w = gray.width, h = gray.height
            result.frameWidth = w
            result.frameHeight = h

            // --- Ball: bright-blob search ---
            if let bright = gray.thresholded(at: brightThreshold) {
                if ballPos == nil {
                    // First sighting: full-frame search for a ball-sized bright blob.
                    if let blob = brightestBallSizedBlob(in: bright, expectedArea: ballArea) {
                        ballPos = blob.centroid
                        result.ballFound = true
                        result.ballPoints.append(TrackedPoint(x: blob.centroid.x, y: blob.centroid.y, time: t))
                    }
                } else if let pos = ballPos {
                    // Tracked: search a small ROI around the last position.
                    let radius = max(80.0, ballDiameterPx * 3.0)
                    let roi = CGRect(x: pos.x - radius, y: pos.y - radius,
                                     width: radius * 2, height: radius * 2)
                    if let blob = brightestBallSizedBlob(in: bright, roi: roi, expectedArea: ballArea) {
                        let dist = hypot(blob.centroid.x - pos.x, blob.centroid.y - pos.y)
                        ballPos = blob.centroid
                        result.ballPoints.append(TrackedPoint(x: blob.centroid.x, y: blob.centroid.y, time: t))
                        if !impactFound, dist > ballDiameterPx * 1.2 {
                            impactFound = true
                            result.impactBallIndex = result.ballPoints.count - 1
                        }
                    }
                    // else: ball left the ROI/frame; keep last known position.
                }
                bright.free()
            }

            // --- Clubhead: motion-blob search, pre-impact only ---
            if !impactFound, let prev = prevGray, let motion = gray.motionMask(vs: prev, threshold: motionThreshold) {
                // Lower 65% of the frame is where the club travels.
                let roi = CGRect(x: 0, y: Double(h) * 0.35, width: Double(w), height: Double(h) * 0.65)
                if let blob = largestBlob(in: motion, roi: roi, minPixels: 40) {
                    result.clubPoints.append(TrackedPoint(x: blob.centroid.x, y: blob.centroid.y, time: t))
                }
                motion.free()
            }

            prevGray?.free()
            prevGray = gray
        }
        prevGray?.free()

        // --- Tempo from the club trail ---
        if let (takeaway, top) = tempoIndices(in: result.clubPoints, impactTime: impactBallTime(in: result)) {
            result.takeawayIndex = takeaway
            result.topOfSwingIndex = top
        }
        return result
    }

    // MARK: Ball diameter detection (calibration)

    /// Finds the ball in a single frame: its center, estimated diameter
    /// (px), using only the bundled on-device Core ML model.
    static func detectBall(in sampleBuffer: CMSampleBuffer) -> BallDetectionOutcome {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return BallDetectionOutcome(ball: nil, failureReason: "Camera frame has no image buffer.")
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        for which in [BundledModel.golfDetector, .cocoDetector] {
            guard let detector = ObjectDetector(which) else { continue }
            let classes: Set<Int>? = which == .cocoDetector ? [32] : nil
            let ball = detector.detectTiled(in: image, tile: 640, confidence: 0.12, classes: classes)
                .first {
                    which == .golfDetector || $0.label.localizedCaseInsensitiveContains("ball")
                }
            if let ball {
                return BallDetectionOutcome(
                    ball: DetectedBall(center: ball.center, diameter: ball.diameter,
                                       frameWidth: CVPixelBufferGetWidth(pixelBuffer),
                                       frameHeight: CVPixelBufferGetHeight(pixelBuffer)),
                    failureReason: nil
                )
            }
        }
        guard let model = Self.loadBundledBallModel() else {
            return BallDetectionOutcome(
                ball: nil,
                failureReason: "No bundled Core ML ball detector could be loaded."
            )
        }

        let visionModel: VNCoreMLModel
        do {
            visionModel = try VNCoreMLModel(for: model)
        } catch {
            return BallDetectionOutcome(
                ball: nil,
                failureReason: "The bundled model can't be used as a Vision object detector: \(error.localizedDescription)"
            )
        }

        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let sem = DispatchSemaphore(value: 0)
        var detected: DetectedBall?
        var failureReason: String?
        let inputDescription = model.modelDescription.inputDescriptionsByName.values.first
        let inputWidth = inputDescription?.imageConstraint?.pixelsWide ?? 640
        let inputHeight = inputDescription?.imageConstraint?.pixelsHigh ?? 640

        let request = VNCoreMLRequest(model: visionModel) { request, error in
            defer { sem.signal() }
            if let error {
                failureReason = "Core ML inference failed: \(error.localizedDescription)"
                return
            }
            guard let featureObservations = request.results as? [VNCoreMLFeatureValueObservation],
                  let output = featureObservations.lazy
                    .compactMap({ $0.featureValue.multiArrayValue })
                    .first
            else {
                let resultTypes = request.results?.map { String(describing: type(of: $0)) } ?? []
                failureReason = "Core ML returned no multi-array detection tensor. Outputs: \(resultTypes.joined(separator: ", "))."
                return
            }

            // The fine-tuned golf model uses 5 values per anchor; COCO uses 84.
            let shape = output.shape.map(\.intValue)
            guard shape.count == 3, shape[0] == 1 else {
                failureReason = "Unsupported YOLO tensor shape: \(shape)."
                return
            }
            let channelsFirst = [5, 84].contains(shape[1]) && shape[2] > shape[1]
            let channelsLast = [5, 84].contains(shape[2]) && shape[1] > shape[2]
            guard channelsFirst || channelsLast else {
                failureReason = "Unsupported YOLO tensor shape: \(shape). Expected 5 or 84 values per anchor."
                return
            }

            let featureCount = channelsFirst ? shape[1] : shape[2]
            let classCount = featureCount - 4
            guard classCount == 1 || classCount == 80 else {
                failureReason = "Unsupported YOLO class count: \(classCount). Expected one golf-ball class or 80 COCO classes."
                return
            }
            let anchorCount = channelsFirst ? shape[2] : shape[1]
            let value: (Int, Int) -> Double = { channel, anchor in
                let indices: [NSNumber] = channelsFirst
                    ? [0, channel, anchor] as [NSNumber]
                    : [0, anchor, channel] as [NSNumber]
                return output[indices].doubleValue
            }
            let golfBallChannel = classCount == 1 ? 4 : 4 + 32
            var bestAnchor: Int?
            var bestConfidence = 0.25
            for anchor in 0..<anchorCount {
                let confidence = value(golfBallChannel, anchor)
                if confidence > bestConfidence {
                    bestConfidence = confidence
                    bestAnchor = anchor
                }
            }
            guard let bestAnchor else {
                let modelName = classCount == 1 ? "GolfBallDetector" : "COCO sports-ball"
                failureReason = "Core ML ran, but \(modelName) found no ball above 0.25 confidence."
                return
            }

            let cx = value(0, bestAnchor)
            let cy = value(1, bestAnchor)
            let boxWidth = value(2, bestAnchor)
            let boxHeight = value(3, bestAnchor)
            let scaleX = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(inputWidth)
            let scaleY = Double(CVPixelBufferGetHeight(pixelBuffer)) / Double(inputHeight)
            let center = CGPoint(x: cx * scaleX, y: cy * scaleY)
            let diameter = max(boxWidth * scaleX, boxHeight * scaleY)
            guard center.x.isFinite, center.y.isFinite, diameter.isFinite, diameter > 0 else {
                failureReason = "YOLO returned an invalid sports-ball bounding box."
                return
            }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            detected = DetectedBall(center: center,
                                    diameter: diameter,
                                    frameWidth: width,
                                    frameHeight: height)
        }
        request.imageCropAndScaleOption = .scaleFill

        do {
            try requestHandler.perform([request])
        } catch {
            return BallDetectionOutcome(
                ball: nil,
                failureReason: "Vision couldn't run the Core ML model: \(error.localizedDescription)"
            )
        }

        sem.wait()
        return BallDetectionOutcome(ball: detected, failureReason: failureReason)
    }

    /// Loads the first local Core ML model that looks like a ball detector.
    private static func loadBundledBallModel() -> MLModel? {
        let candidates = [
            "GolfBallDetector",
            "GolfBall",
            "BallDetector",
            "BallDetection",
            "GolfBallDetection",
            "GolfBallModel",
            "yolov8n",
            "COCODetector",
            "yolov8n 2",
            "yolov8n_coreml",
            "yolov8n-pose",
            "yolov8n_pose_coreml",
            "yolov88n",
            "yolov8n-seg",
            "yolov8n_seg_coreml",
            "yolo11n",
            "yolo11n-pose",
            "yolo11n_pose_coreml"
        ]

        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") ??
                Bundle.main.url(forResource: name, withExtension: "mlmodel") ??
                Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                if let model = try? MLModel(contentsOf: url) {
                    return model
                }
            }
        }

        let modelURLs = (Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []) +
            (Bundle.main.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil) ?? [])
        for url in modelURLs {
            if let model = try? MLModel(contentsOf: url) {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if name.contains("ball") || name.contains("golf") || name.contains("yolov8n") {
                    return model
                }
            }
        }

        return nil
    }

    static func detectBallDiameter(in sampleBuffer: CMSampleBuffer) -> Double? {
        detectBall(in: sampleBuffer).ball?.diameter
    }

    // MARK: Blob helpers

    private struct Blob {
        var centroid: CGPoint
        var pixelCount: Int
        var bbox: CGRect
        /// Second central moments of the blob's pixels.
        var varX: Double = 0
        var varY: Double = 0
        var aspectRatio: Double {
            let w = max(bbox.width, 1), h = max(bbox.height, 1)
            return max(w, h) / min(w, h)
        }
        /// 1.0 = round. From second moments, so it stays meaningful for
        /// small blobs where the grid-snapped bbox aspect is too coarse.
        var elongation: Double {
            let lo = max(min(varX, varY), 1e-6)
            return sqrt(max(varX, varY) / lo)
        }
    }

    /// Brightest blob whose size is within 0.2x–5x of the expected ball area.
    /// Full frame when roi is nil.
    private func brightestBallSizedBlob(in mask: GrayImage, roi: CGRect? = nil, expectedArea: Double) -> Blob? {
        let w = Double(mask.width), h = Double(mask.height)
        let region = roi ?? CGRect(x: 0, y: 0, width: w, height: h)
        let candidates = scanBlobs(in: mask, roi: region, minPixels: 8)
            .filter { Double($0.pixelCount) > expectedArea * 0.2 && Double($0.pixelCount) < expectedArea * 5.0 }
        // Closest to expected size wins (rejects tees, glints, range balls).
        return candidates.min { abs(Double($0.pixelCount) - expectedArea) < abs(Double($1.pixelCount) - expectedArea) }
    }

    private func largestBlob(in mask: GrayImage, roi: CGRect, minPixels: Int) -> Blob? {
        scanBlobs(in: mask, roi: roi, minPixels: minPixels)
            .max { $0.pixelCount < $1.pixelCount }
    }

    /// Thresholded-white-pixel clustering on a coarse grid with 4-connected merge.
    private func scanBlobs(in mask: GrayImage, roi: CGRect, minPixels: Int) -> [Blob] {
        let w = mask.width, h = mask.height
        let cell = 8
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var counts = [Int](repeating: 0, count: gw * gh)
        var sumX = [Double](repeating: 0, count: gw * gh)
        var sumY = [Double](repeating: 0, count: gw * gh)
        var sumX2 = [Double](repeating: 0, count: gw * gh)
        var sumY2 = [Double](repeating: 0, count: gw * gh)

        let x0 = max(0, Int(roi.minX)), x1 = min(w - 1, Int(roi.maxX))
        let y0 = max(0, Int(roi.minY)), y1 = min(h - 1, Int(roi.maxY))
        guard x1 > x0, y1 > y0 else { return [] }

        mask.withUnsafePixels { ptr, rowBytes in
            var y = y0
            while y <= y1 {
                let row = ptr.advanced(by: y * rowBytes)
                var x = x0
                while x <= x1 {
                    if row[x] > 0 {
                        let gi = (y / cell) * gw + (x / cell)
                        counts[gi] += 1
                        sumX[gi] += Double(x)
                        sumY[gi] += Double(y)
                        sumX2[gi] += Double(x * x)
                        sumY2[gi] += Double(y * y)
                    }
                    x += scanStride
                }
                y += scanStride
            }
        }

        var visited = [Bool](repeating: false, count: gw * gh)
        var blobs: [Blob] = []
        let scale = Double(scanStride * scanStride)
        for i in 0..<(gw * gh) where counts[i] > 0 && !visited[i] {
            var queue = [i]
            visited[i] = true
            var total = 0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0
            var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            while let c = queue.popLast() {
                total += counts[c]; sx += sumX[c]; sy += sumY[c]; sxx += sumX2[c]; syy += sumY2[c]
                let ccx = c % gw, ccy = c / gw
                minX = min(minX, Double(ccx * cell)); maxX = max(maxX, Double((ccx + 1) * cell))
                minY = min(minY, Double(ccy * cell)); maxY = max(maxY, Double((ccy + 1) * cell))
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = ccx + dx, ny = ccy + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                    let ni = ny * gw + nx
                    if counts[ni] > 0, !visited[ni] { visited[ni] = true; queue.append(ni) }
                }
            }
            let pixelCount = Int(Double(total) * scale)
            guard total > 0, pixelCount >= minPixels else { continue }
            let meanX = sx / Double(total), meanY = sy / Double(total)
            blobs.append(Blob(
                centroid: CGPoint(x: meanX, y: meanY),
                pixelCount: pixelCount,
                bbox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                varX: max(0, sxx / Double(total) - meanX * meanX),
                varY: max(0, syy / Double(total) - meanY * meanY)
            ))
        }
        return blobs
    }

    // MARK: Tempo

    private func impactBallTime(in result: TrackingResult) -> Double? {
        guard let i = result.impactBallIndex, i < result.ballPoints.count else { return nil }
        return result.ballPoints[i].time
    }

    /// Returns (takeawayIndex, topIndex) into clubPoints, or nil if the swing
    /// couldn't be segmented.
    private func tempoIndices(in trail: [TrackedPoint], impactTime: Double?) -> (Int, Int)? {
        guard trail.count >= 6 else { return nil }
        // Takeaway start: first frame with sustained motion (> 3 px/frame).
        var start: Int?
        for i in 1..<trail.count {
            let d = hypot(trail[i].x - trail[i - 1].x, trail[i].y - trail[i - 1].y)
            if d > 3.0 { start = i - 1; break }
        }
        guard let s = start else { return nil }
        // Top of backswing: highest clubhead point (min y) before impact.
        let endTime = impactTime ?? trail.last!.time
        var top = s, topY = trail[s].y
        for i in s..<trail.count where trail[i].time <= endTime {
            if trail[i].y < topY { topY = trail[i].y; top = i }
        }
        guard top > s else { return nil }
        return (s, top)
    }
}

// MARK: - GrayImage: owned grayscale pixel buffer (no vImage dependency)

/// A grayscale copy of a video frame at half resolution (every 2nd pixel).
/// Owns its memory; call free(). Calibration and tracking both use this
/// space, so the pixel→meter scale stays consistent.
private struct GrayImage {
    var pixels: UnsafeMutablePointer<UInt8>
    var width: Int
    var height: Int

    init?(from pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Half-resolution BGRA → grayscale (luminosity), sampling every 2nd
        // pixel. Manual loop: avoids vImage entry points whose availability
        // varies across SDKs, and quarters the conversion cost.
        let w2 = w / 2, h2 = h / 2
        guard w2 > 4, h2 > 4 else { return nil }
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: w2 * h2)
        let src = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h2 {
            let sRow = src.advanced(by: y * 2 * srcRowBytes)
            let dRow = pixels.advanced(by: y * w2)
            for x in 0..<w2 {
                let o = x * 8 // (x*2) pixels × 4 bytes/pixel
                let r = Int(sRow[o + 2]), g = Int(sRow[o + 1]), b = Int(sRow[o])
                dRow[x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
            }
        }
        self.pixels = pixels
        self.width = w2
        self.height = h2
    }

    private init(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    func free() { pixels.deallocate() }

    func withUnsafePixels(_ body: (UnsafePointer<UInt8>, Int) -> Void) {
        body(UnsafePointer(pixels), width)
    }

    /// Binary mask: 255 where pixel > value.
    func thresholded(at value: UInt8) -> GrayImage? {
        let n = width * height
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        for i in 0..<n {
            out[i] = pixels[i] > value ? 255 : 0
        }
        return GrayImage(pixels: out, width: width, height: height)
    }

    /// Binary mask of pixels that changed vs `other` by more than `threshold`.
    func motionMask(vs other: GrayImage, threshold: UInt8) -> GrayImage? {
        guard other.width == width, other.height == height else { return nil }
        let n = width * height
        let t = Int(threshold)
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        for i in 0..<n {
            let a = Int(pixels[i]), b = Int(other.pixels[i])
            let d = a > b ? a - b : b - a
            out[i] = d > t ? 255 : 0
        }
        return GrayImage(pixels: out, width: width, height: height)
    }
}
