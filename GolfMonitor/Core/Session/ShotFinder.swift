import Foundation

/// Turns a recording's `SceneTimeline` into swings and shots.
///
/// A **swing** is a short, strong burst of motion energy. A **shot** is a
/// swing during which a locked ball disappeared — practice swings leave the
/// ball where it is, the real one sends it away. When no ball strike is
/// found, the last swing is still returned (as `.swingOnly`) so the user gets
/// a tempo/pose analysis instead of nothing.
///
/// Pure value logic: unit-tested with synthetic timelines.
struct ShotFinder {
    struct Config {
        /// Moving-average window for motion energy (seconds).
        var smoothing: Double = 0.15
        /// A burst is motion above `baseline + max(minRise, noiseFactor × MAD)`.
        var minRise: Float = 0.006
        var noiseFactor: Float = 6
        /// A burst whose peak is at least this far above baseline is a swing.
        var swingMinRise: Float = 0.012
        var mergeGap: Double = 0.35
        var minSwingDuration: Double = 0.3
        var maxSwingDuration: Double = 4.0
        /// Ball patch difference above which the ball counts as gone.
        var absentThreshold: Float = 0.14
        /// A ball must stay gone this long to count as hit…
        var minAbsence: Double = 0.6
        /// …or this long if the recording ended right after the strike.
        var minAbsenceAtEnd: Double = 0.2
        /// A disappearance this close to a swing burst belongs to that swing.
        var swingProximity: Double = 0.5
        /// Disappearances closer together than this are simultaneous.
        var simultaneity: Double = 0.1
        /// Clip kept around impact (address → finish).
        var preRoll: Double = 2.4
        var postRoll: Double = 1.4
    }

    struct Swing: Equatable, Sendable {
        var start: Double
        var end: Double
        var peakTime: Double
        var peak: Float
        var isShot: Bool = false
        var duration: Double { end - start }
    }

    struct FoundShot: Equatable, Sendable {
        enum Kind: String, Sendable { case struck, swingOnly }
        var kind: Kind
        /// Best estimate of impact (struck shots only).
        var impactTime: Double?
        var clipStart: Double
        var clipEnd: Double
        /// The ball that was hit (calibration comes from its diameter).
        var ball: BallTrack?
        var swing: Swing?
    }

    struct Result: Equatable, Sendable {
        var swings: [Swing] = []
        var shots: [FoundShot] = []
        var struckCount: Int { shots.filter { $0.kind == .struck }.count }
        var practiceSwingCount: Int { swings.filter { !$0.isShot }.count }
    }

    var config = Config()

    /// - Parameter isFinal: false while still recording (live counters): no
    ///   swing-only fallback, and a ball must have been gone `minAbsence`.
    func analyze(_ timeline: SceneTimeline, isFinal: Bool = true) -> Result {
        var swings = findSwings(in: timeline.motion)
        var shots: [FoundShot] = []

        let departures = cameraMotionFiltered(timeline.balls.compactMap { ball in
            departureTime(of: ball, timelineEnd: timeline.duration, isFinal: isFinal).map { (ball: ball, time: $0) }
        })
        // Earliest disappearance per swing: the struck ball leaves at impact;
        // anything that vanishes later in the same swing was hidden by the follow-through.
        for departure in departures.sorted(by: { $0.time < $1.time }) {
            guard let index = swings.firstIndex(where: {
                departure.time >= $0.start - config.swingProximity && departure.time <= $0.end + config.swingProximity
            }), !swings[index].isShot else { continue }
            swings[index].isShot = true
            shots.append(FoundShot(kind: .struck, impactTime: departure.time,
                                   clipStart: max(0, departure.time - config.preRoll),
                                   clipEnd: min(timeline.duration, departure.time + config.postRoll),
                                   ball: departure.ball, swing: swings[index]))
        }

        if isFinal, shots.isEmpty, let last = swings.last {
            let center = last.peakTime
            let start = max(0, min(last.start - 0.8, center - 2.0))
            let end = min(timeline.duration, max(last.end + 0.6, center + 1.2))
            shots.append(FoundShot(kind: .swingOnly, impactTime: nil, clipStart: start,
                                   clipEnd: max(start, end), ball: nil, swing: last))
        }
        return Result(swings: swings, shots: shots)
    }

    /// The earliest ball strike in a clip that is nothing but one swing (no
    /// still baseline to find swing bursts in) — used for imported / demo clips.
    func firstStrike(in timeline: SceneTimeline) -> (ball: BallTrack, time: Double)? {
        cameraMotionFiltered(timeline.balls.compactMap { ball in
            departureTime(of: ball, timelineEnd: timeline.duration, isFinal: true).map { (ball: ball, time: $0) }
        }).min { $0.time < $1.time }
    }

    /// Several separate balls "vanishing" in the same instant means the
    /// camera moved (bumped tripod), not that they were all hit.
    func cameraMotionFiltered(_ departures: [(ball: BallTrack, time: Double)]) -> [(ball: BallTrack, time: Double)] {
        departures.filter { d in
            !departures.contains { other in
                other.ball.id != d.ball.id && abs(other.time - d.time) <= config.simultaneity
                    && hypot(other.ball.center.x - d.ball.center.x, other.ball.center.y - d.ball.center.y)
                        > CGFloat(2 * max(d.ball.diameterPx, other.ball.diameterPx))
            }
        }
    }

    // MARK: Swings

    func findSwings(in motion: [MotionSample]) -> [Swing] {
        guard motion.count >= 4 else { return [] }
        let smoothed = smooth(motion)
        let energies = smoothed.map(\.energy).sorted()
        let baseline = energies[energies.count / 4]
        let deviations = energies.map { abs($0 - baseline) }.sorted()
        let mad = deviations[deviations.count / 2]
        let threshold = baseline + max(config.minRise, config.noiseFactor * mad)

        // Segments above threshold, merged across short dips.
        var segments: [(start: Int, end: Int)] = []
        var openStart: Int?
        for (i, s) in smoothed.enumerated() {
            if s.energy >= threshold {
                if openStart == nil { openStart = i }
            } else if let start = openStart {
                segments.append((start, i - 1))
                openStart = nil
            }
        }
        if let start = openStart { segments.append((start, smoothed.count - 1)) }

        var merged: [(start: Int, end: Int)] = []
        for seg in segments {
            if let last = merged.last, smoothed[seg.start].t - smoothed[last.end].t <= config.mergeGap {
                merged[merged.count - 1].end = seg.end
            } else {
                merged.append(seg)
            }
        }

        return merged.compactMap { seg in
            let slice = smoothed[seg.start...seg.end]
            guard let peak = slice.max(by: { $0.energy < $1.energy }) else { return nil }
            let swing = Swing(start: smoothed[seg.start].t, end: smoothed[seg.end].t,
                              peakTime: peak.t, peak: peak.energy)
            guard peak.energy - baseline >= config.swingMinRise,
                  swing.duration >= config.minSwingDuration,
                  swing.duration <= config.maxSwingDuration else { return nil }
            return swing
        }
    }

    private func smooth(_ motion: [MotionSample]) -> [MotionSample] {
        let half = config.smoothing / 2
        var out: [MotionSample] = []
        out.reserveCapacity(motion.count)
        var lo = 0, hi = 0
        var sum: Float = 0
        for (i, s) in motion.enumerated() {
            while hi < motion.count, motion[hi].t <= s.t + half { sum += motion[hi].energy; hi += 1 }
            while lo < i, motion[lo].t < s.t - half { sum -= motion[lo].energy; lo += 1 }
            out.append(MotionSample(t: s.t, energy: sum / Float(max(1, hi - lo))))
        }
        return out
    }

    // MARK: Ball departure

    /// When the ball went away for good, if it did: the start of the final
    /// run of "missing" samples, pinned to where the patch jumps to its final
    /// level (a club head leaving the ball at takeaway nudges the patch a
    /// little; the ball leaving changes it completely).
    func departureTime(of ball: BallTrack, timelineEnd: Double, isFinal: Bool) -> Double? {
        let samples = ball.presence
        guard let last = samples.last else { return nil }
        var runStart = samples.count
        while runStart > 0, samples[runStart - 1].difference > config.absentThreshold { runStart -= 1 }
        guard runStart < samples.count else { return nil }

        let levels = samples[runStart...].map(\.difference).sorted()
        let finalLevel = levels[levels.count / 2]
        let strict = max(config.absentThreshold, finalLevel * 0.6)
        var impact = samples.count - 1
        while impact > runStart, samples[impact - 1].difference > strict { impact -= 1 }
        let start = samples[impact].t

        let length = last.t - samples[runStart].t
        let ended = isFinal && timelineEnd - last.t < 0.5
        return length >= (ended ? config.minAbsenceAtEnd : config.minAbsence) ? start : nil
    }
}
