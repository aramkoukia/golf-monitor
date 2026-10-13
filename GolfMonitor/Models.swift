import Foundation
import SwiftUI

// MARK: - Clubs

/// Clubs the user can tag a shot with. Each club also carries a *typical*
/// backspin value (rpm) used only by the carry-distance flight model.
/// These are tour-average-ish figures, not measured spin.
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

    /// Typical backspin (rpm) assumed by the carry model. Nil for putter-like
    /// cases (none defined here). Documented as an assumption, not a measurement.
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
}

// MARK: - Shot

/// One measured shot. Canonical stored units: mph for speeds, yards for
/// distances, seconds for times. Display converts via SettingsStore.
struct Shot: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var club: Club
    var ballSpeedMph: Double
    var clubSpeedMph: Double
    var launchAngleDeg: Double
    var carryYards: Double
    var apexYards: Double
    var hangTimeS: Double
    var smashFactor: Double
    /// Backswing:downswing expressed as X:1 (e.g. 3.0). 0 = unknown.
    var tempoRatio: Double
    /// Lateral miss at carry distance, + = right of target. Side-view estimate.
    var offlineYards: Double
    /// Always nil in v1: a phone camera cannot measure spin. Kept for schema.
    var spinRpmEstimate: Double? = nil
    var notes: String = ""
}

// MARK: - Calibration

/// Camera calibration, persisted in UserDefaults.
struct Calibration: Codable {
    /// Phone-to-ball distance the user measured at setup (informational).
    var distanceToBallMeters: Double = 3.0
    var useFeet: Bool = false
    /// Pixels per meter in the video frame, derived from the golf ball's known
    /// diameter (42.67 mm) detected in a calibration frame.
    var pixelsPerMeter: Double = 800
    /// Detected ball diameter in pixels (used to size-match during tracking).
    var ballDiameterPx: Double? = nil
    /// Set once the user completes calibration.
    var isCalibrated: Bool = false

    static let golfBallDiameterMeters: Double = 0.04267

    private static let key = "golfmonitor.calibration.v1"

    static func load() -> Calibration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(Calibration.self, from: data)
        else { return Calibration() }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Calibration.key)
        }
    }
}

// MARK: - Settings

enum SpeedUnit: String, CaseIterable, Codable {
    case mph = "mph"
    case kmh = "km/h"
}

enum DistanceUnit: String, CaseIterable, Codable {
    case yards = "yards"
    case meters = "meters"
}

/// Display-unit preferences, observable so the UI refreshes on change.
final class SettingsStore: ObservableObject {
    @Published var speedUnit: SpeedUnit {
        didSet { UserDefaults.standard.set(speedUnit.rawValue, forKey: "golfmonitor.speedUnit") }
    }
    @Published var distanceUnit: DistanceUnit {
        didSet { UserDefaults.standard.set(distanceUnit.rawValue, forKey: "golfmonitor.distanceUnit") }
    }

    init() {
        let su = UserDefaults.standard.string(forKey: "golfmonitor.speedUnit")
            .flatMap(SpeedUnit.init(rawValue:)) ?? .mph
        let du = UserDefaults.standard.string(forKey: "golfmonitor.distanceUnit")
            .flatMap(DistanceUnit.init(rawValue:)) ?? .yards
        self.speedUnit = su
        self.distanceUnit = du
    }
}

// MARK: - Formatting helpers

func formatSpeed(mph: Double, settings: SettingsStore) -> String {
    guard mph.isFinite, mph > 0 else { return "—" }
    switch settings.speedUnit {
    case .mph: return String(format: "%.0f mph", mph)
    case .kmh: return String(format: "%.0f km/h", mph * 1.60934)
    }
}

func formatDistance(yards: Double, settings: SettingsStore) -> String {
    guard yards.isFinite, yards >= 0 else { return "—" }
    switch settings.distanceUnit {
    case .yards: return String(format: "%.0f yds", yards)
    case .meters: return String(format: "%.0f m", yards * 0.9144)
    }
}

func formatTempo(_ ratio: Double) -> String {
    guard ratio > 0 else { return "—" }
    return String(format: "%.1f : 1", ratio)
}

func formatOffline(yards: Double, settings: SettingsStore) -> String {
    guard yards.isFinite else { return "—" }
    let magnitude = abs(yards)
    let side = yards > 0.5 ? " R" : (yards < -0.5 ? " L" : "")
    switch settings.distanceUnit {
    case .yards: return String(format: "~%.0f yds%@", magnitude, side)
    case .meters: return String(format: "~%.0f m%@", magnitude * 0.9144, side)
    }
}

// MARK: - Shot store

/// Persists shots as JSON in the app's Documents directory.
final class ShotStore: ObservableObject {
    @Published private(set) var shots: [Shot] = []

    private let fileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shots.json")
    }()

    init() { load() }

    func addShot(_ shot: Shot) {
        shots.insert(shot, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        shots.remove(atOffsets: offsets)
        save()
    }

    func shots(for club: Club?) -> [Shot] {
        guard let club else { return shots }
        return shots.filter { $0.club == club }
    }

    struct ClubAverages {
        var count: Int = 0
        var ballSpeedMph: Double = 0
        var clubSpeedMph: Double = 0
        var carryYards: Double = 0
        var launchAngleDeg: Double = 0
        var smashFactor: Double = 0
    }

    func averages(for club: Club) -> ClubAverages {
        let list = shots(for: club)
        guard !list.isEmpty else { return ClubAverages() }
        let n = Double(list.count)
        return ClubAverages(
            count: list.count,
            ballSpeedMph: list.map(\.ballSpeedMph).reduce(0, +) / n,
            clubSpeedMph: list.map(\.clubSpeedMph).reduce(0, +) / n,
            carryYards: list.map(\.carryYards).reduce(0, +) / n,
            launchAngleDeg: list.map(\.launchAngleDeg).reduce(0, +) / n,
            smashFactor: list.map(\.smashFactor).reduce(0, +) / n
        )
    }

    /// CSV for export via share sheet.
    func csvString() -> String {
        var lines = ["date,club,ball_speed_mph,club_speed_mph,launch_angle_deg,carry_yds,apex_yds,hang_time_s,smash_factor,tempo_ratio,offline_yds,notes"]
        let df = ISO8601DateFormatter()
        for s in shots {
            let notes = s.notes.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append([
                df.string(from: s.date),
                s.club.rawValue,
                String(format: "%.1f", s.ballSpeedMph),
                String(format: "%.1f", s.clubSpeedMph),
                String(format: "%.1f", s.launchAngleDeg),
                String(format: "%.1f", s.carryYards),
                String(format: "%.1f", s.apexYards),
                String(format: "%.2f", s.hangTimeS),
                String(format: "%.2f", s.smashFactor),
                String(format: "%.2f", s.tempoRatio),
                String(format: "%.1f", s.offlineYards),
                "\"\(notes)\""
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Shot].self, from: data)
        else { return }
        shots = decoded
    }
}
