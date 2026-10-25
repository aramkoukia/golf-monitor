import Foundation

/// PGA Tour average launch-monitor numbers per club, from TrackMan's
/// published tour averages. Only metrics the app also produces are kept.
/// Wedges are absent on purpose: pros play them at partial distances, so a
/// single tour average for a wedge doesn't mean much.
struct ProStats {
    var clubSpeedMph: Double
    var ballSpeedMph: Double
    var smashFactor: Double
    var launchAngleDeg: Double
    var carryYards: Double
    var apexYards: Double
}

enum ProReference {
    static func stats(for club: Club) -> ProStats? {
        switch club {
        case .driver:        return ProStats(clubSpeedMph: 113, ballSpeedMph: 167, smashFactor: 1.48, launchAngleDeg: 10.9, carryYards: 275, apexYards: 32)
        case .wood3:         return ProStats(clubSpeedMph: 107, ballSpeedMph: 158, smashFactor: 1.48, launchAngleDeg: 9.2,  carryYards: 243, apexYards: 30)
        case .wood5:         return ProStats(clubSpeedMph: 103, ballSpeedMph: 152, smashFactor: 1.47, launchAngleDeg: 9.4,  carryYards: 230, apexYards: 31)
        case .hybrid:        return ProStats(clubSpeedMph: 100, ballSpeedMph: 146, smashFactor: 1.46, launchAngleDeg: 10.2, carryYards: 225, apexYards: 29)
        case .iron4:         return ProStats(clubSpeedMph: 96,  ballSpeedMph: 137, smashFactor: 1.43, launchAngleDeg: 11.0, carryYards: 203, apexYards: 28)
        case .iron5:         return ProStats(clubSpeedMph: 94,  ballSpeedMph: 132, smashFactor: 1.41, launchAngleDeg: 12.1, carryYards: 194, apexYards: 31)
        case .iron6:         return ProStats(clubSpeedMph: 92,  ballSpeedMph: 127, smashFactor: 1.38, launchAngleDeg: 14.1, carryYards: 183, apexYards: 30)
        case .iron7:         return ProStats(clubSpeedMph: 90,  ballSpeedMph: 120, smashFactor: 1.33, launchAngleDeg: 16.3, carryYards: 172, apexYards: 32)
        case .iron8:         return ProStats(clubSpeedMph: 87,  ballSpeedMph: 115, smashFactor: 1.32, launchAngleDeg: 18.1, carryYards: 160, apexYards: 31)
        case .iron9:         return ProStats(clubSpeedMph: 85,  ballSpeedMph: 109, smashFactor: 1.28, launchAngleDeg: 20.4, carryYards: 148, apexYards: 30)
        case .pitchingWedge, .gapWedge, .sandWedge, .lobWedge:
            return nil
        }
    }
}
