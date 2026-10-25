// Legacy v1 History tab — replaced by Features/Library + Features/Insights. Delete once they ship.
import SwiftUI
import UIKit

/// Session history: filter by club, per-club averages, delete, CSV export.
struct ShotHistoryView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter

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
                if shot.hasMedia {
                    Button {
                        router.openStudio(shot.id)
                    } label: {
                        Label("Analyze", systemImage: "play.rectangle")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
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
