import Foundation

/// Camera calibration, persisted in UserDefaults.
struct Calibration: Codable {
    /// Phone-to-ball distance the user measured at setup (informational).
    var distanceToBallMeters: Double = 3.0
    var useFeet: Bool = false
    /// Pixels per meter in the analysis frame, derived from the golf ball's
    /// known diameter (42.67 mm) detected in a calibration frame.
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
