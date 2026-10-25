import Combine
import Foundation

enum SpeedUnit: String, CaseIterable, Codable {
    case mph = "mph"
    case kmh = "km/h"
}

enum DistanceUnit: String, CaseIterable, Codable {
    case yards = "yards"
    case meters = "meters"
}

/// Camera shutter preference. Short exposures freeze the ball and clubhead
/// (less motion blur → better tracking) but need bright light.
enum ShutterMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case s1000
    case s2000
    case s4000

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .s1000: return "1/1000"
        case .s2000: return "1/2000"
        case .s4000: return "1/4000"
        }
    }

    /// Exposure duration in seconds, nil for auto exposure.
    var seconds: Double? {
        switch self {
        case .auto: return nil
        case .s1000: return 1.0 / 1000
        case .s2000: return 1.0 / 2000
        case .s4000: return 1.0 / 4000
        }
    }
}

/// How a recording is started on the Range screen.
enum CaptureTrigger: String, CaseIterable, Codable, Identifiable {
    /// Arms, then keeps the clip around the impact sound / ball launch.
    case auto
    /// Countdown, then a fixed-length clip (v1 behaviour).
    case timer
    var id: String { rawValue }
    var title: String { self == .auto ? "Auto" : "Timer" }
}

/// User preferences, persisted in UserDefaults. Observable so the UI
/// refreshes on change. Keys from v1 ("golfmonitor.speedUnit", …) are kept.
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var speedUnit: SpeedUnit { didSet { set(speedUnit.rawValue, "speedUnit") } }
    @Published var distanceUnit: DistanceUnit { didSet { set(distanceUnit.rawValue, "distanceUnit") } }
    @Published var handedness: Handedness { didSet { set(handedness.rawValue, "handedness") } }
    @Published var cameraView: CameraView { didSet { set(cameraView.rawValue, "cameraView") } }
    @Published var captureTrigger: CaptureTrigger { didSet { set(captureTrigger.rawValue, "captureTrigger") } }
    @Published var shutterMode: ShutterMode { didSet { set(shutterMode.rawValue, "shutterMode") } }
    @Published var voiceReadout: Bool { didSet { set(voiceReadout, "voiceReadout") } }
    @Published var hapticsEnabled: Bool { didSet { set(hapticsEnabled, "hapticsEnabled") } }
    /// Countdown before a timer-triggered clip (seconds).
    @Published var countdownSeconds: Int { didSet { set(countdownSeconds, "countdownSeconds") } }
    /// Clip length for timer-triggered capture (seconds).
    @Published var clipSeconds: Int { didSet { set(clipSeconds, "clipSeconds") } }
    @Published var playerName: String { didSet { set(playerName, "playerName") } }
    @Published var hasCompletedOnboarding: Bool { didSet { set(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "golfmonitor." + key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: "golfmonitor." + key) as? Bool ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: "golfmonitor." + key) as? Int ?? fallback
        }
        speedUnit = string("speedUnit").flatMap(SpeedUnit.init(rawValue:)) ?? .mph
        distanceUnit = string("distanceUnit").flatMap(DistanceUnit.init(rawValue:)) ?? .yards
        handedness = string("handedness").flatMap(Handedness.init(rawValue:)) ?? .right
        cameraView = string("cameraView").flatMap(CameraView.init(rawValue:)) ?? .faceOn
        captureTrigger = string("captureTrigger").flatMap(CaptureTrigger.init(rawValue:)) ?? .auto
        shutterMode = string("shutterMode").flatMap(ShutterMode.init(rawValue:)) ?? .s2000
        voiceReadout = bool("voiceReadout", true)
        hapticsEnabled = bool("hapticsEnabled", true)
        countdownSeconds = int("countdownSeconds", 5)
        clipSeconds = int("clipSeconds", 3)
        playerName = string("playerName") ?? ""
        hasCompletedOnboarding = bool("hasCompletedOnboarding", false)
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "golfmonitor." + key)
    }

    // MARK: Unit conversion (canonical: mph, yards)

    func speedValue(mph: Double) -> Double {
        speedUnit == .mph ? mph : mph * 1.60934
    }

    var speedUnitLabel: String { speedUnit == .mph ? "mph" : "km/h" }

    func distanceValue(yards: Double) -> Double {
        distanceUnit == .yards ? yards : yards * 0.9144
    }

    var distanceUnitLabel: String { distanceUnit == .yards ? "yds" : "m" }
}

// MARK: - Formatting helpers (v1 API, used across the app)

func formatSpeed(mph: Double, settings: SettingsStore) -> String {
    guard mph.isFinite, mph > 0 else { return "—" }
    return String(format: "%.0f %@", settings.speedValue(mph: mph), settings.speedUnitLabel)
}

func formatDistance(yards: Double, settings: SettingsStore) -> String {
    guard yards.isFinite, yards >= 0 else { return "—" }
    return String(format: "%.0f %@", settings.distanceValue(yards: yards), settings.distanceUnitLabel)
}

func formatTempo(_ ratio: Double) -> String {
    guard ratio > 0, ratio.isFinite else { return "—" }
    return String(format: "%.1f : 1", ratio)
}

func formatOffline(yards: Double, settings: SettingsStore) -> String {
    guard yards.isFinite else { return "—" }
    let side = yards > 0.5 ? " R" : (yards < -0.5 ? " L" : "")
    return String(format: "~%.0f %@%@", settings.distanceValue(yards: abs(yards)), settings.distanceUnitLabel, side)
}
