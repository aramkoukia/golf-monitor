import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// One detection in SOURCE pixel coordinates (top-left origin).
struct Detection: Hashable {
    var rect: CGRect
    var confidence: Float
    var classIndex: Int
    var label: String

    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    /// Ball diameter estimate: the larger box side.
    var diameter: CGFloat { max(rect.width, rect.height) }
}

/// Runs a YOLO detector exported by Ultralytics with `nms=True` (a Core ML
/// pipeline whose outputs are `confidence` [N, C] and `coordinates` [N, 4] —
/// normalized center-x, center-y, width, height in model-input space).
/// Also understands raw single-tensor outputs [1, 4 + C, anchors] (no NMS) so
/// the v1 COCO model keeps working as a fallback.
final class ObjectDetector {
    let model: MLModel
    let classNames: [String]
    private let pre: ImagePreprocessor
    private let inputName: String
    private let inputSide: Int

    init?(model: MLModel) {
        self.model = model
        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }) else { return nil }
        inputName = input.key
        inputSide = input.value.imageConstraint?.pixelsWide ?? 640
        pre = ImagePreprocessor(side: inputSide)
        classNames = ObjectDetector.parseClassNames(desc)
    }

    convenience init?(_ which: BundledModel) {
        guard let m = ModelCatalog.shared.model(which) else { return nil }
        self.init(model: m)
    }

    /// Detect objects in `image` (upright frame), optionally inside `roi`
    /// (source pixels). Results are mapped back to source pixels.
    func detect(in image: CIImage, roi: CGRect? = nil,
                confidence: Float = 0.25, iou: Float = 0.45,
                classes: Set<Int>? = nil) -> [Detection] {
        guard let (buffer, transform) = pre.letterbox(image, crop: roi) else { return [] }
        var features: [String: MLFeatureValue] = [inputName: MLFeatureValue(pixelBuffer: buffer)]
        let inputs = model.modelDescription.inputDescriptionsByName
        if inputs["iouThreshold"] != nil { features["iouThreshold"] = MLFeatureValue(double: Double(iou)) }
        if inputs["confidenceThreshold"] != nil { features["confidenceThreshold"] = MLFeatureValue(double: Double(confidence)) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: features),
              let out = try? model.prediction(from: provider)
        else { return [] }

        let side = CGFloat(inputSide)
        var dets: [Detection] = []
        if let conf = out.featureValue(for: "confidence")?.multiArrayValue,
           let coords = out.featureValue(for: "coordinates")?.multiArrayValue {
            let n = conf.shape.first?.intValue ?? 0
            let c = conf.shape.count > 1 ? conf.shape[1].intValue : 1
            for i in 0..<n {
                var best = 0, bestScore: Float = 0
                for k in 0..<c {
                    let s = conf[[i, k] as [NSNumber]].floatValue
                    if s > bestScore { bestScore = s; best = k }
                }
                guard bestScore >= confidence, classes?.contains(best) ?? true else { continue }
                let cx = CGFloat(coords[[i, 0] as [NSNumber]].floatValue) * side
                let cy = CGFloat(coords[[i, 1] as [NSNumber]].floatValue) * side
                let w = CGFloat(coords[[i, 2] as [NSNumber]].floatValue) * side
                let h = CGFloat(coords[[i, 3] as [NSNumber]].floatValue) * side
                let r = transform.toSource(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
                dets.append(Detection(rect: r, confidence: bestScore, classIndex: best, label: name(best)))
            }
        } else if let raw = out.featureNames.lazy.compactMap({ out.featureValue(for: $0)?.multiArrayValue }).first {
            dets = decodeRaw(raw, transform: transform, confidence: confidence, iou: iou, classes: classes)
        }
        return dets.sorted { $0.confidence > $1.confidence }
    }

    /// Runs `detect` over overlapping square tiles covering `region` at native
    /// resolution, so tiny balls aren't shrunk away by a full-frame resize.
    func detectTiled(in image: CIImage, region: CGRect? = nil, tile: CGFloat? = nil, overlap: CGFloat = 0.2,
                     confidence: Float = 0.25, classes: Set<Int>? = nil) -> [Detection] {
        let full = CGRect(x: 0, y: 0, width: image.extent.width, height: image.extent.height)
        let area = (region ?? full).intersection(full)
        guard !area.isEmpty else { return [] }
        let tileSize = tile ?? CGFloat(inputSide)
        guard tileSize.isFinite, tileSize > 0, overlap.isFinite, (0..<1).contains(overlap) else { return [] }
        let stride = tileSize * (1 - overlap)
        var all: [Detection] = []
        var y = area.minY
        repeat {
            var x = area.minX
            repeat {
                let r = CGRect(x: x, y: y, width: tileSize, height: tileSize).intersection(area)
                all += detect(in: image, roi: r, confidence: confidence, classes: classes)
                x += stride
            } while x + tileSize * overlap < area.maxX
            y += stride
        } while y + tileSize * overlap < area.maxY
        return ObjectDetector.nms(all, iou: 0.4)
    }

    // MARK: Helpers

    private func name(_ i: Int) -> String { i < classNames.count ? classNames[i] : "class\(i)" }

    private func decodeRaw(_ out: MLMultiArray, transform: LetterboxTransform,
                           confidence: Float, iou: Float, classes: Set<Int>?) -> [Detection] {
        let shape = out.shape.map(\.intValue)
        guard shape.count == 3 else { return [] }
        let channelsFirst = shape[1] < shape[2]
        let channels = channelsFirst ? shape[1] : shape[2]
        let anchors = channelsFirst ? shape[2] : shape[1]
        let numClasses = channels - 4
        guard numClasses > 0 else { return [] }
        let ptr = out.dataPointer.bindMemory(to: Float.self, capacity: out.count)
        let isFloat32 = out.dataType == .float32
        func v(_ ch: Int, _ a: Int) -> Float {
            let idx = channelsFirst ? ch * anchors + a : a * channels + ch
            return isFloat32 ? ptr[idx] : out[idx].floatValue
        }
        var dets: [Detection] = []
        for a in 0..<anchors {
            var best = 0, bestScore: Float = 0
            for k in 0..<numClasses where classes?.contains(k) ?? true {
                let s = v(4 + k, a)
                if s > bestScore { bestScore = s; best = k }
            }
            guard bestScore >= confidence else { continue }
            let cx = CGFloat(v(0, a)), cy = CGFloat(v(1, a)), w = CGFloat(v(2, a)), h = CGFloat(v(3, a))
            let r = transform.toSource(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            dets.append(Detection(rect: r, confidence: bestScore, classIndex: best, label: name(best)))
        }
        return ObjectDetector.nms(dets, iou: iou)
    }

    static func nms(_ dets: [Detection], iou threshold: Float) -> [Detection] {
        var kept: [Detection] = []
        for d in dets.sorted(by: { $0.confidence > $1.confidence }) {
            if kept.allSatisfy({ $0.classIndex != d.classIndex || iou($0.rect, d.rect) < CGFloat(threshold) }) {
                kept.append(d)
            }
        }
        return kept
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// Ultralytics stores class names in user metadata as a Python dict
    /// string: "{0: 'golf_ball', 1: 'club_head'}".
    private static func parseClassNames(_ desc: MLModelDescription) -> [String] {
        let meta = desc.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let raw = meta["names"] else { return [] }
        var names: [Int: String] = [:]
        let pattern = try? NSRegularExpression(pattern: #"(\d+)\s*:\s*'([^']*)'"#)
        let ns = raw as NSString
        pattern?.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, let i = Int(ns.substring(with: m.range(at: 1))) else { return }
            names[i] = ns.substring(with: m.range(at: 2))
        }
        return (0..<(names.keys.max().map { $0 + 1 } ?? 0)).map { names[$0] ?? "class\($0)" }
    }
}
