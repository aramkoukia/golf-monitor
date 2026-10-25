import Foundation

/// PGA Tour average launch-monitor numbers per club, from TrackMan's
/// published tour averages (club speed, attack angle, ball speed, smash,
/// launch, spin, max height, land angle, carry). Gap/sand/lob wedges are
/// absent on purpose: pros play them at partial distances, so a single tour
/// average doesn't mean much.
struct ProStats {
    var clubSpeedMph: Double
    var ballSpeedMph: Double
    var smashFactor: Double
    var launchAngleDeg: Double
    var carryYards: Double
    var apexYards: Double
    /// Attack angle (°, negative = descending blow).
    var attackAngleDeg: Double? = nil
    /// Backspin (rpm) — the app cannot measure it; shown for context only.
    var spinRpm: Double? = nil
    /// Landing (descent) angle (°).
    var landAngleDeg: Double? = nil
}

enum ProReference {
    static func stats(for club: Club) -> ProStats? {
        switch club {
        case .driver:        return ProStats(clubSpeedMph: 113, ballSpeedMph: 167, smashFactor: 1.48, launchAngleDeg: 10.9, carryYards: 275, apexYards: 32, attackAngleDeg: -1.3, spinRpm: 2686, landAngleDeg: 38)
        case .wood3:         return ProStats(clubSpeedMph: 107, ballSpeedMph: 158, smashFactor: 1.48, launchAngleDeg: 9.2,  carryYards: 243, apexYards: 30, attackAngleDeg: -2.9, spinRpm: 3655, landAngleDeg: 43)
        case .wood5:         return ProStats(clubSpeedMph: 103, ballSpeedMph: 152, smashFactor: 1.47, launchAngleDeg: 9.4,  carryYards: 230, apexYards: 31, attackAngleDeg: -3.3, spinRpm: 4350, landAngleDeg: 47)
        case .hybrid:        return ProStats(clubSpeedMph: 100, ballSpeedMph: 146, smashFactor: 1.46, launchAngleDeg: 10.2, carryYards: 225, apexYards: 29, attackAngleDeg: -3.5, spinRpm: 4437, landAngleDeg: 47)
        case .iron4:         return ProStats(clubSpeedMph: 96,  ballSpeedMph: 137, smashFactor: 1.43, launchAngleDeg: 11.0, carryYards: 203, apexYards: 28, attackAngleDeg: -3.4, spinRpm: 4836, landAngleDeg: 48)
        case .iron5:         return ProStats(clubSpeedMph: 94,  ballSpeedMph: 132, smashFactor: 1.41, launchAngleDeg: 12.1, carryYards: 194, apexYards: 31, attackAngleDeg: -3.7, spinRpm: 5361, landAngleDeg: 49)
        case .iron6:         return ProStats(clubSpeedMph: 92,  ballSpeedMph: 127, smashFactor: 1.38, launchAngleDeg: 14.1, carryYards: 183, apexYards: 30, attackAngleDeg: -4.1, spinRpm: 6231, landAngleDeg: 50)
        case .iron7:         return ProStats(clubSpeedMph: 90,  ballSpeedMph: 120, smashFactor: 1.33, launchAngleDeg: 16.3, carryYards: 172, apexYards: 32, attackAngleDeg: -4.3, spinRpm: 7097, landAngleDeg: 50)
        case .iron8:         return ProStats(clubSpeedMph: 87,  ballSpeedMph: 115, smashFactor: 1.32, launchAngleDeg: 18.1, carryYards: 160, apexYards: 31, attackAngleDeg: -4.5, spinRpm: 7998, landAngleDeg: 50)
        case .iron9:         return ProStats(clubSpeedMph: 85,  ballSpeedMph: 109, smashFactor: 1.28, launchAngleDeg: 20.4, carryYards: 148, apexYards: 30, attackAngleDeg: -4.7, spinRpm: 8647, landAngleDeg: 51)
        case .pitchingWedge: return ProStats(clubSpeedMph: 83, ballSpeedMph: 102, smashFactor: 1.23, launchAngleDeg: 24.2, carryYards: 136, apexYards: 29, attackAngleDeg: -5.0, spinRpm: 9304, landAngleDeg: 52)
        case .gapWedge, .sandWedge, .lobWedge:
            return nil
        }
    }
}
