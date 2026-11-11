import CoreGraphics
import Foundation

/// Simple 2D pose measurements. These are image-plane observations, not
/// clinical angles or 3D estimates, so no tour ratings are assigned.
enum PoseMetrics {
    struct Tip: Identifiable {
        var id: String
        var title: String
        var observation: String
        var suggestion: String
    }

    static func tips(from metrics: [SwingMetric]) -> [Tip] {
        metrics.compactMap { metric in
            let measurement = String(format: "%.1f %@", metric.value, metric.unit)
            let content: (title: String, suggestion: String)? = switch metric.id {
            case "pose.torsoLean2D":
                ("Torso line at setup",
                 "Compare this setup with your comfortable address position from the same camera view. There is no universal target angle from 2D video.")
            case "pose.kneeFlex2D":
                ("Knee bend at setup",
                 "Review the address frame and check that your bend feels comfortable and balanced. Use the image as a reference, not a target angle.")
            case "pose.headMovement":
                ("Head movement through the swing",
                 "Replay the swing and notice when this side-to-side movement occurs. Compare with another similar view rather than trying to hold your head rigid.")
            case "pose.hipSway":
                ("Hip movement through the swing",
                 "Compare address, top, and impact. This is left/right movement in the image; it does not measure hip rotation or weight transfer.")
            default:
                nil
            }
            guard let content else { return nil }
            return Tip(id: metric.id, title: content.title,
                       observation: "Estimated \(measurement) in this video.",
                       suggestion: content.suggestion)
        }
    }

    static func metrics(from poses: [PoseSample]) -> [SwingMetric] {
        guard let address = poses.first else { return [] }
        var result: [SwingMetric] = []

        if let shoulders = midpoint(address, .leftShoulder, .rightShoulder),
           let hips = midpoint(address, .leftHip, .rightHip) {
            let dx = Double(shoulders.x - hips.x)
            let dy = Double(hips.y - shoulders.y)
            let torsoLength = hypot(dx, dy)
            if torsoLength > 0.02 {
                let torsoAngle = abs(atan2(dx, dy) * 180 / .pi)
                result.append(SwingMetric(
                    id: "pose.torsoLean2D", name: "Torso lean (2D)", value: torsoAngle, unit: "°",
                    rating: .unrated,
                    explanation: "Shoulder-to-hip line from vertical in the image at the first detected pose; camera angle affects this estimate."
                ))

                if let head = address.point(.nose) {
                    let headTravel = poses.compactMap { pose -> CGFloat? in
                        guard let point = pose.point(.nose), let center = midpoint(pose, .leftHip, .rightHip) else {
                            return nil
                        }
                        return abs((point.x - center.x) - (head.x - hips.x))
                    }.max()
                    if let headTravel {
                        result.append(SwingMetric(
                            id: "pose.headMovement", name: "Head movement", value: Double(headTravel / torsoLength * 100),
                            unit: "% torso",
                            rating: .unrated,
                            explanation: "Maximum side-to-side head movement relative to the hip center, scaled by torso length in the image."
                        ))
                    }
                }

                let hipTravel = poses.compactMap { pose -> CGFloat? in
                    guard let center = midpoint(pose, .leftHip, .rightHip) else { return nil }
                    return abs(center.x - hips.x)
                }.max()
                if let hipTravel {
                    result.append(SwingMetric(
                        id: "pose.hipSway", name: "Hip sway", value: Double(hipTravel / torsoLength * 100),
                        unit: "% torso",
                        rating: .unrated,
                        explanation: "Maximum horizontal hip-center movement from the first detected pose, scaled by torso length."
                    ))
                }
            }
        }

        var kneeFlex: [Double] = []
        for (hip, knee, ankle) in [
            (BodyJoint.leftHip, BodyJoint.leftKnee, BodyJoint.leftAnkle),
            (.rightHip, .rightKnee, .rightAnkle),
        ] {
            guard let h = address.point(hip), let k = address.point(knee), let a = address.point(ankle) else {
                continue
            }
            let first = CGPoint(x: h.x - k.x, y: h.y - k.y)
            let second = CGPoint(x: a.x - k.x, y: a.y - k.y)
            let denominator = hypot(first.x, first.y) * hypot(second.x, second.y)
            guard denominator > 0.0001 else { continue }
            let cosine = max(-1, min(1, Double((first.x * second.x + first.y * second.y) / denominator)))
            kneeFlex.append(180 - acos(cosine) * 180 / .pi)
        }
        if !kneeFlex.isEmpty {
            result.append(SwingMetric(
                id: "pose.kneeFlex2D", name: "Knee bend (2D)",
                value: kneeFlex.reduce(0, +) / Double(kneeFlex.count), unit: "°",
                rating: .unrated,
                explanation: "Average projected knee bend from the first detected pose; perspective and occlusion affect the estimate."
            ))
        }
        return result
    }

    private static func midpoint(_ pose: PoseSample, _ first: BodyJoint, _ second: BodyJoint) -> CGPoint? {
        guard let a = pose.point(first), let b = pose.point(second) else { return nil }
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
