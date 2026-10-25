import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter

    private var measuredShots: [Shot] { store.shots.filter(\.hasLaunchData) }
    private var chartShots: [Shot] { Array(measuredShots.prefix(20).reversed()) }

    var body: some View {
        NavigationStack {
            ZStack {
                NightRangeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if measuredShots.isEmpty {
                            ContentUnavailableView {
                                Label("Insights appear after your first measured shot", systemImage: "chart.xyaxis.line")
                            } description: {
                                Text("Record a face-on swing with a calibrated ball to see carry and speed trends.")
                            } actions: {
                                Button("Go to Range") { router.tab = .range }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 72)
                        } else {
                            summaryCards
                            carryTrend
                            clubSummary
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Insights")
        }
    }

    private var summaryCards: some View {
        let averageCarry = measuredShots.map(\.carryYards).reduce(0, +) / Double(measuredShots.count)
        let averageSpeed = measuredShots.map(\.ballSpeedMph).reduce(0, +) / Double(measuredShots.count)
        let bestCarry = measuredShots.map(\.carryYards).max() ?? 0
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            insightCard("MEASURED SHOTS", "\(measuredShots.count)", icon: "figure.golf")
            insightCard("AVG CARRY", formatDistance(yards: averageCarry, settings: settings), icon: "arrow.up.right")
            insightCard("AVG BALL SPEED", formatSpeed(mph: averageSpeed, settings: settings), icon: "speedometer")
            insightCard("BEST CARRY", formatDistance(yards: bestCarry, settings: settings), icon: "trophy")
        }
    }

    private var carryTrend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Carry trend").font(.headline)
            if chartShots.count < 2 {
                Text("Record another measured shot to see your trend.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart(chartShots) { shot in
                    LineMark(x: .value("Date", shot.date), y: .value("Carry", shot.carryYards))
                        .foregroundStyle(Theme.Palette.plasma)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Date", shot.date), y: .value("Carry", shot.carryYards))
                        .foregroundStyle(Theme.Palette.tracerCore)
                }
                .chartYAxisLabel(settings.distanceUnitLabel)
                .frame(height: 190)
            }
        }
        .insightPanel()
    }

    private var clubSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By club").font(.headline)
            ForEach(Club.allCases) { club in
                let averages = store.averages(for: club)
                if averages.count > 0 {
                    HStack {
                        Text(club.rawValue).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(averages.count) shots")
                            .foregroundStyle(.secondary)
                        Text(formatDistance(yards: averages.carryYards, settings: settings))
                            .monospacedDigit()
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .font(.subheadline)
                }
            }
        }
        .insightPanel()
    }

    private func insightCard(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.plasma)
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding()
        .insightPanel()
    }
}

private extension View {
    func insightPanel() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.carbon, in: RoundedRectangle(cornerRadius: 16))
    }
}
