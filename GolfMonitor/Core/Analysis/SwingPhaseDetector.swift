import CoreGraphics
import Foundation

/// The eight swing positions from the lead wrist's path. When the impact
/// time is known (from the ball leaving), it anchors everything: the top is
/// the highest wrist point in the 1.6 s before impact and the takeaway is
/// where the wrist last sat still before rising. Without it, the wrist's
/// low → high → low pattern is used.
enum SwingPhaseDetector {
    static func phases(from poses: [PoseSample], handedness: Handedness, impactTime: Double?) -> [SwingPhaseMarker] {
        let lead: BodyJoint = handedness == .right ? .leftWrist : .rightWrist
        let trail: BodyJoint = handedness == .right ? .rightWrist : .leftWrist
        let path: [(t: Double, p: CGPoint)] = poses.compactMap { pose in
            guard let point = pose.point(lead) ?? pose.point(trail) else { return nil }
            return (pose.t, point)
        }
        guard path.count >= 6 else { return [] }
        if let impactTime { return anchored(path, impact: impactTime) }
        return unanchored(path)
    }

    private static func anchored(_ path: [(t: Double, p: CGPoint)], impact: Double) -> [SwingPhaseMarker] {
        let backswing = path.filter { $0.t >= impact - 1.6 && $0.t <= impact - 0.12 }
        guard let top = backswing.min(by: { $0.p.y < $1.p.y }) else { return [] }
        let before = path.filter { $0.t < top.t && $0.t >= top.t - 1.8 }
        guard let rest = before.first else { return [] }
        // Takeaway: the last moment the wrist was still near where it started.
        let rise = Double(rest.p.y - top.p.y)
        guard rise > 0.05 else { return [] }
        let takeaway = before.last { Double(hypot($0.p.x - rest.p.x, $0.p.y - rest.p.y)) < max(0.02, rise * 0.08) }?.t ?? rest.t
        let finish = min(path.last?.t ?? impact + 0.8, impact + 1.0)
        return markers(address: takeaway, top: top.t, impact: impact, finish: max(finish, impact + 0.05),
                       confidence: 0.6)
    }

    private static func unanchored(_ path: [(t: Double, p: CGPoint)]) -> [SwingPhaseMarker] {
        let addressY = path.prefix(5).map(\.p.y).sorted()[min(2, path.prefix(5).count - 1)]
        var minIndex = 0
        var topIndex: Int?
        for (i, s) in path.enumerated() {
            if s.p.y < path[minIndex].p.y { minIndex = i }
            let rise = addressY - path[minIndex].p.y
            if rise > 0.08, s.p.y > path[minIndex].p.y + 0.5 * rise { topIndex = minIndex; break }
        }
        guard let ti = topIndex else { return [] }
        let top = path[ti]
        let window = path[(ti + 1)...].prefix { $0.t - top.t <= 0.5 }
        guard let impact = window.max(by: { $0.p.y < $1.p.y }) else { return [] }
        let start = path.first!.t
        return markers(address: start + (top.t - start) * 0.2, top: top.t, impact: impact.t,
                       finish: path.last!.t, confidence: 0.3)
    }

    /// `address` is the moment the club starts back (takeaway start).
    private static func markers(address: Double, top: Double, impact: Double,
                                finish: Double, confidence: Double) -> [SwingPhaseMarker] {
        func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
        return [
            SwingPhaseMarker(phase: .address, t: address, confidence: confidence),
            SwingPhaseMarker(phase: .toeUp, t: lerp(address, top, 0.3), confidence: confidence * 0.6),
            SwingPhaseMarker(phase: .midBackswing, t: lerp(address, top, 0.6), confidence: confidence * 0.6),
            SwingPhaseMarker(phase: .top, t: top, confidence: confidence),
            SwingPhaseMarker(phase: .midDownswing, t: lerp(top, impact, 0.5), confidence: confidence * 0.7),
            SwingPhaseMarker(phase: .impact, t: impact, confidence: min(1, confidence + 0.3)),
            SwingPhaseMarker(phase: .midFollowThrough, t: lerp(impact, finish, 0.35), confidence: confidence * 0.6),
            SwingPhaseMarker(phase: .finish, t: finish, confidence: confidence),
        ]
    }

    /// Tempo metrics from the markers (backswing ÷ downswing, PGA Tour ≈ 3:1).
    static func tempoMetrics(from phases: [SwingPhaseMarker]) -> [SwingMetric] {
        guard let takeaway = phases.first(where: { $0.phase == .address }),
              let top = phases.first(where: { $0.phase == .top }),
              let impact = phases.first(where: { $0.phase == .impact }),
              top.t > takeaway.t, impact.t > top.t else { return [] }
        let back = top.t - takeaway.t
        let down = impact.t - top.t
        guard back > 0.2, down > 0.08 else { return [] }
        let ratio = back / down
        let tour = 2.7...3.3
        let rating = SwingFeedback.tempoRating(ratio) ?? .unrated
        return [
            SwingMetric(id: "tempo.ratio", name: "Tempo", value: ratio, unit: ":1", tourRange: tour, rating: rating,
                        explanation: "Backswing time divided by downswing time. Tour players average about 3:1."),
            SwingMetric(id: "tempo.backswing", name: "Backswing", value: back, unit: "s", phase: .top,
                        tourRange: 0.7...1.0, explanation: "Takeaway to the top."),
            SwingMetric(id: "tempo.downswing", name: "Downswing", value: down, unit: "s", phase: .impact,
                        tourRange: 0.23...0.33, explanation: "Top to impact."),
        ]
    }
}

enum SwingFeedback {
    struct Summary {
        var focus: String
        var positive: String
        var focusRating: MetricRating
        var positiveRating: MetricRating
    }

    static func tempoRating(_ ratio: Double) -> MetricRating? {
        guard ratio.isFinite, ratio > 0 else { return nil }
        if (2.7...3.3).contains(ratio) { return .tour }
        if (2.2...3.9).contains(ratio) { return .good }
        return .needsWork
    }

    static func tempoLabel(_ ratio: Double) -> String {
        switch tempoRating(ratio) {
        case .tour: return "ON REF"
        case .good: return "NEAR REF"
        case .needsWork: return "CHECK"
        case .unrated, .none: return "UNRATED"
        }
    }

    static func summary(metrics: [SwingMetric], poseCount: Int, tempoRatio: Double = 0) -> Summary {
        let tempo = metrics.first { $0.id == "tempo.ratio" }
        let ratio = tempo?.value ?? tempoRatio
        let rating = tempoRating(ratio)
        let poseMetrics = metrics.filter { $0.id.hasPrefix("pose.") }

        let focus: String
        let focusRating: MetricRating
        if rating == .needsWork {
            focus = String(format: "Tempo is %.1f:1, outside the broad 2.2–3.9:1 reference band.", ratio)
            focusRating = .needsWork
        } else if let metric = poseMetrics.first {
            focus = "Review \(metric.name.lowercased()) against a similar swing; this 2D estimate alone cannot establish a fault."
            focusRating = .unrated
        } else {
            focus = "No reliable posture or rhythm issue was established from this clip."
            focusRating = .unrated
        }

        let positive: String
        let positiveRating: MetricRating
        switch rating {
        case .tour:
            positive = String(format: "Tempo is %.1f:1, within the 2.7–3.3:1 reference band.", ratio)
            positiveRating = .tour
        case .good:
            positive = String(format: "Tempo is %.1f:1, within the broader 2.2–3.9:1 reference band.", ratio)
            positiveRating = .good
        default:
            if poseCount > 0 {
                positive = "Body pose was tracked in \(poseCount) frames; posture remains unscored and can be reviewed in the clip."
            } else {
                positive = "No separate positive posture rating can be supported by this clip yet."
            }
            positiveRating = .unrated
        }
        return Summary(focus: focus, positive: positive,
                       focusRating: focusRating, positiveRating: positiveRating)
    }
}
