import Foundation

// MARK: - Clubs

enum ClubCategory: String, Codable, CaseIterable {
    case driver, wood, hybrid, iron, wedge
}

/// Clubs the user can tag a shot with. Raw values are persisted in shots.json,
/// so they must never change. Each club also carries *typical* loft and
/// backspin values used only by the flight model — tour-average-ish figures,
/// not measurements.
enum Club: String, CaseIterable, Codable, Identifiable {
    case driver = "Driver"
    case wood3 = "3 Wood"
    case wood5 = "5 Wood"
    case hybrid = "Hybrid"
    case iron4 = "4 Iron"
    case iron5 = "5 Iron"
    case iron6 = "6 Iron"
    case iron7 = "7 Iron"
    case iron8 = "8 Iron"
    case iron9 = "9 Iron"
    case pitchingWedge = "Pitching Wedge"
    case gapWedge = "Gap Wedge"
    case sandWedge = "Sand Wedge"
    case lobWedge = "Lob Wedge"

    var id: String { rawValue }

    /// Compact label for chips and chart axes ("DR", "7i", "PW").
    var shortName: String {
        switch self {
        case .driver: return "DR"
        case .wood3: return "3W"
        case .wood5: return "5W"
        case .hybrid: return "HY"
        case .iron4: return "4i"
        case .iron5: return "5i"
        case .iron6: return "6i"
        case .iron7: return "7i"
        case .iron8: return "8i"
        case .iron9: return "9i"
        case .pitchingWedge: return "PW"
        case .gapWedge: return "GW"
        case .sandWedge: return "SW"
        case .lobWedge: return "LW"
        }
    }

    var category: ClubCategory {
        switch self {
        case .driver: return .driver
        case .wood3, .wood5: return .wood
        case .hybrid: return .hybrid
        case .iron4, .iron5, .iron6, .iron7, .iron8, .iron9: return .iron
        case .pitchingWedge, .gapWedge, .sandWedge, .lobWedge: return .wedge
        }
    }

    /// Typical static loft in degrees.
    var loftDeg: Double {
        switch self {
        case .driver: return 10.5
        case .wood3: return 15
        case .wood5: return 18
        case .hybrid: return 21
        case .iron4: return 22
        case .iron5: return 25
        case .iron6: return 28
        case .iron7: return 32
        case .iron8: return 36
        case .iron9: return 40
        case .pitchingWedge: return 45
        case .gapWedge: return 50
        case .sandWedge: return 54
        case .lobWedge: return 58
        }
    }

    /// Typical backspin (rpm) assumed by the carry model. An assumption, not
    /// a measurement — a phone camera cannot resolve ball rotation.
    var typicalSpinRpm: Double {
        switch self {
        case .driver: return 2600
        case .wood3: return 3800
        case .wood5: return 4200
        case .hybrid: return 4800
        case .iron4: return 5200
        case .iron5: return 5700
        case .iron6: return 6200
        case .iron7: return 6800
        case .iron8: return 7700
        case .iron9: return 8700
        case .pitchingWedge: return 9300
        case .gapWedge: return 9700
        case .sandWedge: return 10200
        case .lobWedge: return 9000
        }
    }

    /// Position in the bag, longest club first. Used for sorting and charts.
    var bagOrder: Int { Club.allCases.firstIndex(of: self) ?? 0 }
}
