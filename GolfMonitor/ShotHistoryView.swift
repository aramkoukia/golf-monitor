import SwiftUI
import UIKit

/// Session history: filter by club, per-club averages, delete, CSV export.
struct ShotHistoryView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var filterClub: Club? = nil
    @State private var showShare = false
    @State private var showMetricGuide = false
    @State private var compareShot: Shot? = nil
    @State private var csvURL: URL?

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    private let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d, yyyy"
        return df
    }()

    /// Shots grouped by calendar day, newest day first — the Photos
    /// "Days" arrangement. Shots within a day are newest first too.
    private func dayGroups(_ list: [Shot]) -> [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { cal.startOfDay(for: $0.date) }
        return grouped
            .map { DayGroup(day: $0.key, shots: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                clubFilterBar

                Button {
                    showMetricGuide = true
                } label: {
                    Label("What these numbers mean", systemImage: "info.circle")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .sheet(isPresented: $showMetricGuide) {
                    MetricGuideView()
                }

                if let club = filterClub {
                    averagesCard(for: club)
                }

                let list = store.shots(for: filterClub)
                if list.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "flag")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(filterClub == nil ? "No shots yet" : "No \(filterClub!.rawValue) shots yet")
                            .foregroundStyle(.secondary)
                        Text("Record your first shot in the Session tab.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(dayGroups(list)) { group in
                            Section {
                                ForEach(group.shots) { shot in
                                    shotRow(shot)
                                }
                                .onDelete { offsets in
                                    // Map section offsets back to the store.
                                    let ids = offsets.map { group.shots[$0].id }
                                    for id in ids {
                                        if let idx = store.shots.firstIndex(where: { $0.id == id }) {
                                            store.delete(at: IndexSet(integer: idx))
                                        }
                                    }
                                }
                            } header: {
                                Text(dayFormatter.string(from: group.day))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .sheet(item: $compareShot) { shot in
                        ProCompareView(shot: shot)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportCSV()
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.shots.isEmpty)
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = csvURL { ShareSheet(items: [url]) }
            }
        }
    }

    // MARK: Club filter

    private var clubFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", selected: filterClub == nil) {
                    filterClub = nil
                }
                ForEach(Club.allCases) { club in
                    filterChip(title: club.rawValue, selected: filterClub == club) {
                        filterClub = (filterClub == club) ? nil : club
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
    }

    // MARK: Averages

    private func averagesCard(for club: Club) -> some View {
        let avg = store.averages(for: club)
        return Group {
            if avg.count > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(club.rawValue) · \(avg.count) shot\(avg.count == 1 ? "" : "s") avg")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            avgStat("Carry", formatDistance(yards: avg.carryYards, settings: settings))
                            avgStat("Ball Speed", formatSpeed(mph: avg.ballSpeedMph, settings: settings))
                            avgStat("Club Speed", formatSpeed(mph: avg.clubSpeedMph, settings: settings))
                        }
                        GridRow {
                            avgStat("Smash Factor", avg.smashFactor > 0 ? String(format: "%.2f", avg.smashFactor) : "—")
                            avgStat("Launch Angle", String(format: "%.0f°", avg.launchAngleDeg))
                            avgStat("Offline", formatOffline(yards: avg.offlineYards, settings: settings))
                        }
                        GridRow {
                            avgStat("Apex", formatDistance(yards: avg.apexYards, settings: settings))
                            avgStat("Hang Time", String(format: "%.1fs", avg.hangTimeS))
                            avgStat("Tempo", formatTempo(avg.tempoRatio))
                        }
                    }
                    if avg.count >= 2 {
                        let bests = store.bests(for: club)
                        Text("PERSONAL BEST")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                avgStat("Carry", formatDistance(yards: bests.carryYards, settings: settings), tint: .green)
                                avgStat("Ball Speed", formatSpeed(mph: bests.ballSpeedMph, settings: settings), tint: .green)
                                avgStat("Club Speed", formatSpeed(mph: bests.clubSpeedMph, settings: settings), tint: .green)
                            }
                            GridRow {
                                avgStat("Smash Factor", bests.smashFactor > 0 ? String(format: "%.2f", bests.smashFactor) : "—", tint: .green)
                                avgStat("Offline", formatBestOffline(bests.offlineAbsYards), tint: .green)
                            }
                        }
                    }
                    if let pro = ProReference.stats(for: club) {
                        Text("PGA TOUR AVERAGE")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                avgStat("Carry", formatDistance(yards: pro.carryYards, settings: settings), tint: .blue)
                                avgStat("Ball Speed", formatSpeed(mph: pro.ballSpeedMph, settings: settings), tint: .blue)
                                avgStat("Club Speed", formatSpeed(mph: pro.clubSpeedMph, settings: settings), tint: .blue)
                            }
                            GridRow {
                                avgStat("Smash Factor", String(format: "%.2f", pro.smashFactor), tint: .blue)
                                avgStat("Launch Angle", String(format: "%.0f°", pro.launchAngleDeg), tint: .blue)
                                avgStat("Apex", formatDistance(yards: pro.apexYards, settings: settings), tint: .blue)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
    }

    private func avgStat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    private func shotRow(_ shot: Shot) -> some View {
        let bests = store.bests(for: shot.club)
        // A PB only means something against at least one other shot.
        let multi = bests.count >= 2
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shot.club.rawValue)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(dateFormatter.string(from: shot.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    rowStat("Carry", formatDistance(yards: shot.carryYards, settings: settings),
                            isBest: multi && shot.carryYards >= bests.carryYards)
                    rowStat("Ball Speed", formatSpeed(mph: shot.ballSpeedMph, settings: settings),
                            isBest: multi && shot.ballSpeedMph >= bests.ballSpeedMph)
                    rowStat("Club Speed", formatSpeed(mph: shot.clubSpeedMph, settings: settings),
                            isBest: multi && shot.clubSpeedMph > 0 && shot.clubSpeedMph >= bests.clubSpeedMph)
                }
                GridRow {
                    rowStat("Smash Factor", shot.smashFactor > 0 ? String(format: "%.2f", shot.smashFactor) : "—",
                            isBest: multi && shot.smashFactor > 0 && shot.smashFactor >= bests.smashFactor)
                    rowStat("Launch Angle", String(format: "%.0f°", shot.launchAngleDeg))
                    rowStat("Offline", formatOffline(yards: shot.offlineYards, settings: settings),
                            isBest: multi && bests.offlineAbsYards > 0.05
                                    && abs(shot.offlineYards) <= bests.offlineAbsYards)
                }
                GridRow {
                    rowStat("Apex", formatDistance(yards: shot.apexYards, settings: settings))
                    rowStat("Hang Time", String(format: "~%.1fs", shot.hangTimeS))
                    rowStat("Tempo", formatTempo(shot.tempoRatio))
                }
                GridRow {
                    rowStat("Spin", shot.spinRpmEstimate.map { "\(Int($0)) rpm" } ?? "n/a")
                }
            }
            HStack {
                Spacer()
                Button {
                    compareShot = shot
                } label: {
                    Label("Compare vs Pro", systemImage: "chart.bar.xaxis")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func rowStat(_ label: String, _ value: String, isBest: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(isBest ? value + " ★" : value)
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(isBest ? Color.green : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Offline personal best is a distance from the line, with no side.
    private func formatBestOffline(_ absYards: Double) -> String {
        switch settings.distanceUnit {
        case .yards: return String(format: "~%.0f yds", absYards)
        case .meters: return String(format: "~%.0f m", absYards * 0.9144)
        }
    }

    // MARK: CSV export

    private func exportCSV() {
        let csv = store.csvString()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("golfmonitor-shots.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            csvURL = url
            showShare = true
        } catch {
            // Best effort: nothing to show if the write fails.
        }
    }
}

// MARK: - Day grouping

/// One calendar day's worth of shots, for the Photos-style grouped list.
private struct DayGroup: Identifiable {
    let day: Date
    let shots: [Shot]
    var id: Date { day }
}

// MARK: - Metric guide

/// Plain-English explanations of every shot metric, in the same importance
/// order used on the Session and History screens: outcome and strike
/// quality first, fine detail last. Shared by both screens.
struct MetricGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let kind: String
        let text: String
    }

    private let entries: [Entry] = [
        Entry(name: "Carry", kind: "ESTIMATED",
              text: "How far the ball flies before it lands, not counting roll — the number most players judge a shot by. Estimated by a flight model, so the club you pick matters: the model assumes that club's typical spin."),
        Entry(name: "Ball Speed", kind: "MEASURED",
              text: "How fast the ball leaves the clubface — the biggest single factor in distance. Every extra 1 mph is worth roughly 2 yards of carry. Typical driver speed: 130–150 mph for amateurs, 165+ on tour."),
        Entry(name: "Club Speed", kind: "ESTIMATED",
              text: "How fast the clubhead is moving at impact — your raw power input. Read from the club's motion just before impact, so it's rougher than ball speed, and it shows — when the swing wasn't tracked cleanly. Typical driver: 85–95 mph amateur, 110+ tour."),
        Entry(name: "Smash Factor", kind: "DERIVED",
              text: "Ball speed ÷ club speed: how squarely you struck it. 1.50 is the practical max with a driver, about 1.35–1.40 with irons. Normal club speed but low smash means a mishit — heel, toe, thin or fat. Shows — when club speed is missing."),
        Entry(name: "Launch Angle", kind: "MEASURED",
              text: "The angle the ball takes off at, read from its first frames of flight. Pairs with spin to shape the shot: roughly 10–14° is the driver sweet spot, and irons launch higher."),
        Entry(name: "Offline", kind: "ROUGH GUIDE",
              text: "Estimated finish left or right of the target line at carry distance (+ = right). A side-on camera can't truly see left/right — this is inferred from the ball's path on screen, so it often reads ~0. The least reliable number in the app."),
        Entry(name: "Apex", kind: "ESTIMATED",
              text: "The highest point of the flight. Very high usually means ballooning or too much spin; very low means a runner that may not hold a green."),
        Entry(name: "Hang Time", kind: "ESTIMATED",
              text: "How long the ball stays in the air. Mostly a byproduct of launch angle and apex — a trajectory check, not a goal in itself."),
        Entry(name: "Tempo", kind: "ESTIMATED",
              text: "Backswing time ÷ downswing time, written as X : 1. Tour players cluster near 3 : 1, and a repeatable tempo makes a repeatable swing. Needs the whole swing tracked cleanly — it shows — when the swing can't be segmented."),
        Entry(name: "Spin", kind: "NOT MEASURABLE",
              text: "Backspin, in rpm. A phone camera would have to watch the dimples rotate thousands of times a second — it can't, so this is always n/a. The carry model uses your club's typical spin instead."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Text("Ball speed and launch angle are measured from the video. Carry, apex and hang time come from a flight model that assumes typical backspin for the club you picked — good to about ±10%, not radar-grade.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name)
                                .font(.headline)
                            Spacer()
                            Text(entry.kind)
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("What the numbers mean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

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
