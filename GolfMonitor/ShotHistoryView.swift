import SwiftUI
import UIKit

/// Session history: filter by club, per-club averages, delete, CSV export.
struct ShotHistoryView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var filterClub: Club? = nil
    @State private var showShare = false
    @State private var showMetricGuide = false
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showMetricGuide = true
                    } label: {
                        Label("About the metrics", systemImage: "info.circle")
                    }
                    .sheet(isPresented: $showMetricGuide) {
                        MetricGuideView()
                    }
                }
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
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                              alignment: .leading, spacing: 8) {
                        avgStat("Carry", formatDistance(yards: avg.carryYards, settings: settings))
                        avgStat("Ball", formatSpeed(mph: avg.ballSpeedMph, settings: settings))
                        avgStat("Club", formatSpeed(mph: avg.clubSpeedMph, settings: settings))
                        avgStat("Smash", avg.smashFactor > 0 ? String(format: "%.2f", avg.smashFactor) : "—")
                        avgStat("Launch", String(format: "%.0f°", avg.launchAngleDeg))
                        avgStat("Offline", formatOffline(yards: avg.offlineYards, settings: settings))
                        avgStat("Apex", formatDistance(yards: avg.apexYards, settings: settings))
                        avgStat("Hang", String(format: "%.1fs", avg.hangTimeS))
                        avgStat("Tempo", formatTempo(avg.tempoRatio))
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 8) {
                rowStat("Carry", formatDistance(yards: shot.carryYards, settings: settings))
                rowStat("Ball", formatSpeed(mph: shot.ballSpeedMph, settings: settings))
                rowStat("Club", formatSpeed(mph: shot.clubSpeedMph, settings: settings))
                rowStat("Smash", shot.smashFactor > 0 ? String(format: "%.2f", shot.smashFactor) : "—")
                rowStat("Launch", String(format: "%.0f°", shot.launchAngleDeg))
                rowStat("Offline", formatOffline(yards: shot.offlineYards, settings: settings))
                rowStat("Apex", formatDistance(yards: shot.apexYards, settings: settings))
                rowStat("Hang", String(format: "~%.1fs", shot.hangTimeS))
                rowStat("Tempo", formatTempo(shot.tempoRatio))
                rowStat("Spin", shot.spinRpmEstimate.map { "\(Int($0)) rpm" } ?? "n/a")
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
