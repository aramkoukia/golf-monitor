import CoreML
import Foundation

/// The on-device models bundled under Resources/MLModels (precompiled
/// .mlmodelc — see ml/README.md for how each is trained/exported).
enum BundledModel: String, CaseIterable {
    /// Golf ball (+ club head when available) detector, YOLO with NMS.
    case golfDetector = "GolfDetector"
    /// COCO-17 keypoint pose (YOLO11n-pose), fallback when Vision is unavailable.
    case golferPose = "GolferPose"
    /// Generic COCO detector (v1 model) — last-resort "sports ball" fallback.
    case cocoDetector = "COCODetector"
    /// SwingNet (GolfDB) per-frame encoder: 160×160 image → 1280-d feature.
    case swingNetEncoder = "SwingNetEncoder"
    /// SwingNet BiLSTM head: [1, 64, 1280] features → [1, 64, 9] event logits.
    case swingNetSequence = "SwingNetSequence"

    var url: URL? {
        // "<Name>Dev.mlmodelc" is a local, uncommitted development model
        // (see .gitignore) used until the trained model is bundled.
        Bundle.main.url(forResource: rawValue, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: rawValue + "Dev", withExtension: "mlmodelc")
    }

    var isAvailable: Bool { url != nil }
}

/// Loads and caches MLModels. Thread-safe.
final class ModelCatalog {
    static let shared = ModelCatalog()

    private var cache: [BundledModel: MLModel] = [:]
    private let lock = NSLock()

    func model(_ which: BundledModel) -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let m = cache[which] { return m }
        guard let url = which.url else { return nil }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        guard let m = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        cache[which] = m
        return m
    }

    /// Short description for the About screen / analysis.pipeline string.
    func describe(_ which: BundledModel) -> String {
        guard let m = model(which) else { return "\(which.rawValue) (missing)" }
        let meta = m.modelDescription.metadata
        let author = meta[.author] as? String ?? ""
        let version = meta[.versionString] as? String ?? ""
        return [which.rawValue, version, author].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
