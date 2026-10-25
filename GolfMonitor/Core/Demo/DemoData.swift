import Foundation
import UIKit

/// Demo content so the app looks alive on first launch / in the simulator:
/// a few weeks of synthetic range sessions plus two real CC0 swing clips
/// (bundled in Resources/Demo) analyzed on-device.
enum DemoData {

    /// Bundled CC0 clips (Wikimedia Commons, "Suvichaya Vinijchaitham Golf
    /// Swing Slow Mo 2026", CC0) cut to single swings at 240 fps.
    static let bundledClips: [(name: String, club: Club, view: CameraView)] = [
        ("demo_faceon_driver", .driver, .faceOn),
        ("demo_dtl_iron", .iron7, .downTheLine),
    ]

    /// Seeds synthetic history (instant) and then analyzes the bundled clips
    /// in the background. Safe to call repeatedly: only seeds an empty store.
    @MainActor
    static func seedIfEmpty(_ store: ShotStore, settings: SettingsStore) {
        guard store.shots.isEmpty else { return }
        for shot in syntheticHistory() { store.addShot(shot) }
        Task { await importBundledClips(into: store, handedness: settings.handedness) }
    }

    @MainActor
    static func importBundledClips(into store: ShotStore, handedness: Handedness) async {
        for clip in bundledClips {
            guard let src = Bundle.main.url(forResource: clip.name, withExtension: "mp4") else { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try? FileManager.default.copyItem(at: src, to: tmp)
            let request = AnalysisRequest(clipURL: tmp, club: clip.club, cameraView: clip.view,
                                          handedness: handedness, calibration: nil)
            guard let output = try? await SwingAnalyzer().analyze(request) else { continue }
            var shot = Shot.make(from: output, request: request, source: .demo)
            shot.notes = "Demo swing (CC0 footage)"
            store.addShot(shot, clipURL: tmp, analysis: output.analysis, thumbnail: output.thumbnail)
        }
    }

    /// ~6 weeks of plausible amateur sessions (deterministic).
    static func syntheticHistory(now: Date = Date()) -> [Shot] {
        var rng = SeededGenerator(seed: 42)
        let clubs: [Club] = [.driver, .wood3, .hybrid, .iron5, .iron7, .iron9, .pitchingWedge]
        let skill = 0.86 // fraction of tour speed
        var shots: [Shot] = []
        for sessionIndex in 0..<9 {
            let day = Calendar.current.date(byAdding: .day, value: -(sessionIndex * 5 + 1), to: now) ?? now
            let sessionID = UUID()
            let progress = Double(9 - sessionIndex) / 9 // later sessions slightly better
            for club in clubs {
                let pro = ProReference.stats(for: club)
                for k in 0..<Int.random(in: 3...6, using: &rng) {
                    let base = pro?.ballSpeedMph ?? 95
                    let ball = base * (skill + 0.03 * progress) * (1 + rng.normal() * 0.035)
                    let smash = max(1.1, (pro?.smashFactor ?? 1.25) - 0.04 + rng.normal() * 0.03)
                    let launch = (pro?.launchAngleDeg ?? 26) + rng.normal() * 2.2
                    let carry = (pro?.carryYards ?? 115) * pow(ball / base, 1.6) * (1 + rng.normal() * 0.03)
                    var s = Shot(
                        date: day.addingTimeInterval(Double(club.bagOrder * 300 + k * 45)),
                        club: club,
                        ballSpeedMph: ball, clubSpeedMph: ball / smash, launchAngleDeg: launch,
                        carryYards: carry, apexYards: (pro?.apexYards ?? 26) * (carry / (pro?.carryYards ?? 115)),
                        hangTimeS: 3.5 + carry / 60, smashFactor: smash,
                        tempoRatio: 2.7 + rng.normal() * 0.25 + progress * 0.2,
                        offlineYards: rng.normal() * carry * 0.06,
                        sessionID: sessionID, cameraView: .faceOn, source: .demo
                    )
                    s.backswingTimeS = 0.82 + rng.normal() * 0.06
                    s.downswingTimeS = s.backswingTimeS! / s.tempoRatio
                    s.swingScore = Int(min(98, max(40, 62 + progress * 14 + rng.normal() * 8)))
                    s.metricSummary = ["tempo.ratio": s.tempoRatio, "head.sway.top": 3 + rng.normal() * 2]
                    shots.append(s)
                }
            }
        }
        return shots.sorted { $0.date > $1.date }
    }
}

/// Small deterministic RNG (SplitMix64) with a Box–Muller normal.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
