import SwiftUI

// MARK: - Pro comparison

/// One shot side-by-side with the PGA Tour average for its club:
/// your value, the tour value, and the difference.
struct ProCompareView: View {
    let shot: Shot
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("PGA Tour averages for the \(shot.club.rawValue), from TrackMan's published tour data. Context, not a target — these are the best players in the world with fitted gear.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let pro = ProReference.stats(for: shot.club) {
                    Section {
                        compareRow("Carry",
                                   you: formatDistance(yards: shot.carryYards, settings: settings),
                                   tour: formatDistance(yards: pro.carryYards, settings: settings),
                                   delta: distanceDelta(shot.carryYards - pro.carryYards),
                                   highlight: shot.carryYards >= pro.carryYards)
                        compareRow("Ball Speed",
                                   you: formatSpeed(mph: shot.ballSpeedMph, settings: settings),
                                   tour: formatSpeed(mph: pro.ballSpeedMph, settings: settings),
                                   delta: speedDelta(shot.ballSpeedMph - pro.ballSpeedMph),
                                   highlight: shot.ballSpeedMph >= pro.ballSpeedMph)
                        compareRow("Club Speed",
                                   you: formatSpeed(mph: shot.clubSpeedMph, settings: settings),
                                   tour: formatSpeed(mph: pro.clubSpeedMph, settings: settings),
                                   delta: shot.clubSpeedMph > 0 ? speedDelta(shot.clubSpeedMph - pro.clubSpeedMph) : "—",
                                   highlight: shot.clubSpeedMph > 0 && shot.clubSpeedMph >= pro.clubSpeedMph)
                        compareRow("Smash Factor",
                                   you: shot.smashFactor > 0 ? String(format: "%.2f", shot.smashFactor) : "—",
                                   tour: String(format: "%.2f", pro.smashFactor),
                                   delta: shot.smashFactor > 0 ? numberDelta(shot.smashFactor - pro.smashFactor) : "—",
                                   highlight: shot.smashFactor > 0 && shot.smashFactor >= pro.smashFactor)
                        compareRow("Launch Angle",
                                   you: String(format: "%.1f°", shot.launchAngleDeg),
                                   tour: String(format: "%.1f°", pro.launchAngleDeg),
                                   delta: numberDelta(shot.launchAngleDeg - pro.launchAngleDeg, digits: 1, unit: "°"),
                                   highlight: false)
                        compareRow("Apex",
                                   you: formatDistance(yards: shot.apexYards, settings: settings),
                                   tour: formatDistance(yards: pro.apexYards, settings: settings),
                                   delta: distanceDelta(shot.apexYards - pro.apexYards),
                                   highlight: false)
                    } header: {
                        HStack {
                            Text("Metric")
                                .frame(width: 92, alignment: .leading)
                            Spacer()
                            Text("You")
                                .frame(width: 72, alignment: .trailing)
                            Text("Tour")
                                .frame(width: 72, alignment: .trailing)
                            Text("Diff")
                                .frame(width: 76, alignment: .trailing)
                        }
                        .textCase(nil)
                    }
                    Section {
                        Text("Launch and apex differences aren't scored — the right values depend on your speed and spin. Not compared: offline and tempo (no tour reference in the table), hang time (not published), and spin (the app can't measure it; the tour driver average is about 2,700 rpm).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("No standard tour reference for the \(shot.club.rawValue) — pros play wedges at partial distances, so a single average wouldn't mean much.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("You vs PGA Tour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func compareRow(_ name: String, you: String, tour: String, delta: String, highlight: Bool) -> some View {
        HStack {
            Text(name)
                .font(.subheadline.bold())
                .frame(width: 92, alignment: .leading)
            Spacer()
            Text(you)
                .font(.subheadline.bold())
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Text(tour)
                .font(.subheadline)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Text(delta)
                .font(.caption.bold())
                .monospacedDigit()
                .foregroundStyle(highlight ? Color.green : Color.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private func speedDelta(_ dMph: Double) -> String {
        let sign = dMph > 0 ? "+" : ""
        switch settings.speedUnit {
        case .mph: return String(format: "%@%.0f mph", sign, dMph)
        case .kmh: return String(format: "%@%.0f km/h", sign, dMph * 1.60934)
        }
    }

    private func distanceDelta(_ dYards: Double) -> String {
        let sign = dYards > 0 ? "+" : ""
        switch settings.distanceUnit {
        case .yards: return String(format: "%@%.0f yds", sign, dYards)
        case .meters: return String(format: "%@%.0f m", sign, dYards * 0.9144)
        }
    }

    private func numberDelta(_ d: Double, digits: Int = 2, unit: String = "") -> String {
        let sign = d > 0 ? "+" : ""
        return String(format: "%@%.*f%@", sign, digits, d, unit)
    }
}
