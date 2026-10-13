import SwiftUI
import UIKit

/// Session history: filter by club, per-club averages, delete, CSV export.
struct ShotHistoryView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var filterClub: Club? = nil
    @State private var showShare = false
    @State private var csvURL: URL?

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                clubFilterBar

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
                        ForEach(list) { shot in
                            shotRow(shot)
                        }
                        .onDelete { offsets in
                            // Map filtered-list offsets back to the store.
                            let ids = offsets.map { list[$0].id }
                            for id in ids {
                                if let idx = store.shots.firstIndex(where: { $0.id == id }) {
                                    store.delete(at: IndexSet(integer: idx))
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
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
                    HStack(spacing: 20) {
                        avgStat("Ball", formatSpeed(mph: avg.ballSpeedMph, settings: settings))
                        avgStat("Carry", formatDistance(yards: avg.carryYards, settings: settings))
                        avgStat("Smash", String(format: "%.2f", avg.smashFactor))
                        avgStat("Launch", String(format: "%.0f°", avg.launchAngleDeg))
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

    private func avgStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
    }

    // MARK: Rows

    private func shotRow(_ shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shot.club.rawValue)
                    .font(.headline)
                Spacer()
                Text(dateFormatter.string(from: shot.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                rowStat("Ball", formatSpeed(mph: shot.ballSpeedMph, settings: settings))
                rowStat("Carry", formatDistance(yards: shot.carryYards, settings: settings))
                rowStat("Launch", String(format: "%.0f°", shot.launchAngleDeg))
                rowStat("Smash", shot.smashFactor > 0 ? String(format: "%.2f", shot.smashFactor) : "—")
            }
        }
        .padding(.vertical, 4)
    }

    private func rowStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
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
