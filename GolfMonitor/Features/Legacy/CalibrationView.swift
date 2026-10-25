// Legacy v1 Setup tab — replaced by Features/Settings. Delete once SettingsView ships.
import SwiftUI

/// Setup tab: display-unit settings only. Ball calibration lives on the
/// Session screen (Detect ball) — recording stays locked until it's done.
struct CalibrationView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Display units") {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases, id: \.self) { u in Text(u.rawValue).tag(u) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Distance", selection: $settings.distanceUnit) {
                        ForEach(DistanceUnit.allCases, id: \.self) { u in Text(u.rawValue).tag(u) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Setup")
        }
    }
}
