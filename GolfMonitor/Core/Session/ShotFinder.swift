import Foundation

/// Turns a recording's `SceneTimeline` into swings and shots.
///
/// A **swing** is a short, strong burst of motion energy. A **shot** is a
/// swing during which a locked ball disappeared — practice swings leave the
/// ball where it is, the real one sends it away. When no ball strike is
/// found, the last swing is still returned (as `.swingOnly`) so the user gets
/// a tempo/pose analysis instead of nothing.
///
/// Rushed routines work too (press record, walk up, swing straight away,
/// walk back, press stop):
///  - the bar for "motion" is set from the recording's quietest moments
///    only, so a recording that is mostly movement can't raise its own bar;
///  - a burst that is too long to be one swing (walk up → set up → swing with
///    no pause) is split at its dips;
///  - motion already going on when the recording starts, or when it was
///    stopped on the phone, is the golfer at the phone, not a swing (unless a
///    ball was struck in it).
///
/// Pure value logic: unit-tested with synthetic timelines.
struct ShotFinder {
    struct Config {
        /// Moving-average window for motion energy (seconds).
        var smoothing: Double = 0.15
        /// The "still" level: this percentile of the smoothed motion energy.
        var baselinePercentile: Double = 0.1
        /// Noise is measured on this quietest fraction of the recording only.
        var quietFraction: Double = 0.3
        /// A burst is motion above `baseline + clamp(noiseFactor × noise, minRise...maxRise)`.
        /// `maxRise` stays below `swingMinRise`, so a swing can never be
        /// hidden by a bar the rest of the recording pushed up.
        var minRise: Float = 0.006
        var maxRise: Float = 0.01
        var noiseFactor: Float = 6
        /// A burst whose peak is at least this far above baseline is a swing.
        var swingMinRise: Float = 0.012
        var mergeGap: Double = 0.35
        var minSwingDuration: Double = 0.3
        var maxSwingDuration: Double = 4.0
        /// A burst that has to be split is cut at its deepest dip, if that dip
        /// falls to this fraction (above baseline) of the lower peak beside it.
        var splitDepth: Float = 0.6
        /// Motion this close to the start of the recording (or to its end, when
        /// it was stopped on the phone) is someone at the phone.
        var edgeMargin: Double = 0.25
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

    /// Where the golfer was at the phone (pressing record / stop), as
    /// timeline times. Motion touching these ends is them, not a swing.
    struct Edges: Equatable {
        var start: Double?
        var end: Double?
        static let none = Edges()
    }

    /// - Parameters:
    ///   - isFinal: false while still recording (live counters): no
    ///     swing-only fallback, and a ball must have been gone `minAbsence`.
    ///   - stoppedAtPhone: the recording was stopped on the phone itself, so
    ///     whoever pressed stop walked up to it at the end.
    ///   - ignorePhoneEdges: imported clips contain no phone-control movement.
    func analyze(_ timeline: SceneTimeline, isFinal: Bool = true, stoppedAtPhone: Bool = false,
                 ignorePhoneEdges: Bool = false) -> Result {
        // Live recordings include phone-control movement at their edges; imports don't.
        let edges = ignorePhoneEdges ? Edges.none
            : Edges(start: timeline.motion.first?.t, end: isFinal && stoppedAtPhone ? timeline.duration : nil)
        guard let levels = self.levels(of: timeline.motion) else { return Result() }
        var candidates = swings(in: levels, edges: edges)
        var shots: [FoundShot] = []

        let departures = cameraMotionFiltered(timeline.balls.compactMap { ball in
            departureTime(of: ball, timelineEnd: timeline.duration, isFinal: isFinal).map { (ball: ball, time: $0) }
        })
        // Earliest disappearance per swing: the struck ball leaves at impact;
        // anything that vanishes later in the same swing was hidden by the follow-through.
        for departure in departures.sorted(by: { $0.time < $1.time }) {
            var index = candidates.firstIndex(where: {
                departure.time >= $0.start - config.swingProximity && departure.time <= $0.end + config.swingProximity
            })
            // A ball that left during motion no swing was found in (too long,
            // too short) was still hit: build the swing around the strike.
            if index == nil, let rescued = swing(around: departure.time, in: levels) {
                candidates.append(rescued)
                candidates.sort { $0.start < $1.start }
                index = candidates.firstIndex(of: rescued)
            }
            guard let index, !candidates[index].isShot else { continue }
            candidates[index].isShot = true
            shots.append(FoundShot(kind: .struck, impactTime: departure.time,
                                   clipStart: max(0, departure.time - config.preRoll),
                                   clipEnd: min(timeline.duration, departure.time + config.postRoll),
                                   ball: departure.ball, swing: candidates[index]))
        }

        // Walking to and from the phone isn't a swing (and isn't worth a
        // swing-only analysis): only a strike makes motion at an edge count.
        let reported = candidates.filter { $0.isShot || !touches(edges, start: $0.start, end: $0.end) }
        if isFinal, shots.isEmpty, let last = reported.last {
            let center = last.peakTime
            let start = max(0, min(last.start - 0.8, center - 2.0))
            let end = min(timeline.duration, max(last.end + 0.6, center + 1.2))
            shots.append(FoundShot(kind: .swingOnly, impactTime: nil, clipStart: start,
                                   clipEnd: max(start, end), ball: nil, swing: last))
        }
        return Result(swings: reported, shots: shots)
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

    /// Smoothed motion and the levels measured on it.
    struct Levels {
        var smoothed: [MotionSample]
        var baseline: Float
        var threshold: Float
    }

    private typealias Segment = (start: Int, end: Int)

    /// Every swing-shaped burst, including those at `edges` (callers decide
    /// what those are).
    func findSwings(in motion: [MotionSample], edges: Edges = .none) -> [Swing] {
        levels(of: motion).map { swings(in: $0, edges: edges) } ?? []
    }

    /// The still level is a low percentile of the motion and the noise is the
    /// spread of the quietest samples, so stillness only has to be a small
    /// part of the recording. The rise above the still level is capped below
    /// `swingMinRise`: however busy the recording, a swing clears the bar.
    func levels(of motion: [MotionSample]) -> Levels? {
        guard motion.count >= 4 else { return nil }
        let smoothed = smooth(motion)
        let energies = smoothed.map(\.energy).sorted()
        let baseline = energies[Int(Double(energies.count - 1) * config.baselinePercentile)]
        let quiet = energies.prefix(max(4, Int(Double(energies.count) * config.quietFraction)))
        let deviations = quiet.map { abs($0 - baseline) }.sorted()
        let noise = deviations[deviations.count / 2]
        let rise = min(config.maxRise, max(config.minRise, config.noiseFactor * noise))
        return Levels(smoothed: smoothed, baseline: baseline, threshold: baseline + rise)
    }

    private func swings(in levels: Levels, edges: Edges) -> [Swing] {
        let s = levels.smoothed
        func mustSplit(_ seg: Segment) -> Bool {
            s[seg.end].t - s[seg.start].t > config.maxSwingDuration
                || touches(edges, start: s[seg.start].t, end: s[seg.end].t)
        }
        return bursts(in: levels)
            .flatMap { split($0, in: s, baseline: levels.baseline, while: mustSplit) }
            .compactMap { seg in
                guard let peak = s[seg.start...seg.end].max(by: { $0.energy < $1.energy }) else { return nil }
                let swing = Swing(start: s[seg.start].t, end: s[seg.end].t, peakTime: peak.t, peak: peak.energy)
                guard peak.energy - levels.baseline >= config.swingMinRise,
                      swing.duration >= config.minSwingDuration,
                      swing.duration <= config.maxSwingDuration else { return nil }
                return swing
            }
    }

    /// Runs above the threshold, merged across short dips.
    private func bursts(in levels: Levels) -> [Segment] {
        let s = levels.smoothed
        var segments: [Segment] = []
        var openStart: Int?
        for (i, sample) in s.enumerated() {
            if sample.energy >= levels.threshold {
                if openStart == nil { openStart = i }
            } else if let start = openStart {
                segments.append((start, i - 1))
                openStart = nil
            }
        }
        if let start = openStart { segments.append((start, s.count - 1)) }

        var merged: [Segment] = []
        for seg in segments {
            if let last = merged.last, s[seg.start].t - s[last.end].t <= config.mergeGap {
                merged[merged.count - 1].end = seg.end
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// Cuts a burst at its deepest dip — the pause between walking up and
    /// swinging, or between the finish and walking back — and keeps cutting
    /// the pieces that still `need` it. A dip only counts if it falls to
    /// `splitDepth` of the lower peak beside it; a burst without one stays whole.
    private func split(_ seg: Segment, in s: [MotionSample], baseline: Float,
                       while needed: (Segment) -> Bool, depth: Int = 0) -> [Segment] {
        guard depth < 8, seg.end - seg.start >= 2, needed(seg) else { return [seg] }
        let count = seg.end - seg.start + 1
        var leftPeak = [Float](repeating: 0, count: count)
        var rightPeak = [Float](repeating: 0, count: count)
        for k in 0..<count {
            leftPeak[k] = max(k > 0 ? leftPeak[k - 1] : 0, s[seg.start + k].energy)
            let j = count - 1 - k
            rightPeak[j] = max(j < count - 1 ? rightPeak[j + 1] : 0, s[seg.start + j].energy)
        }
        var best: (index: Int, ratio: Float)?
        for i in (seg.start + 1)..<seg.end
        where s[i].energy <= s[i - 1].energy && s[i].energy <= s[i + 1].energy {
            let flank = min(leftPeak[i - seg.start], rightPeak[i - seg.start]) - baseline
            guard flank > 0 else { continue }
            let ratio = (s[i].energy - baseline) / flank
            if ratio <= config.splitDepth, ratio < (best?.ratio ?? .infinity) { best = (i, ratio) }
        }
        guard let cut = best?.index else { return [seg] }
        return split((seg.start, cut), in: s, baseline: baseline, while: needed, depth: depth + 1)
            + split((cut + 1, seg.end), in: s, baseline: baseline, while: needed, depth: depth + 1)
    }

    /// Whether a span runs into an end of the recording someone was at the phone for.
    func touches(_ edges: Edges, start: Double, end: Double) -> Bool {
        if let edge = edges.start, start - edge <= config.edgeMargin { return true }
        if let edge = edges.end, edge - end <= config.edgeMargin { return true }
        return false
    }

    /// The swing around a strike that no swing was found for: the motion
    /// burst it happened in, trimmed to the clip window around impact.
    private func swing(around time: Double, in levels: Levels) -> Swing? {
        let s = levels.smoothed
        guard let seg = bursts(in: levels).first(where: {
            time >= s[$0.start].t - config.swingProximity && time <= s[$0.end].t + config.swingProximity
        }) else { return nil }
        let window = (time - config.preRoll)...(time + config.postRoll)
        let samples = s[seg.start...seg.end].filter { window.contains($0.t) }
        guard let first = samples.first, let last = samples.last,
              let peak = samples.max(by: { $0.energy < $1.energy }) else { return nil }
        return Swing(start: min(first.t, time), end: max(last.t, time), peakTime: peak.t, peak: peak.energy)
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
