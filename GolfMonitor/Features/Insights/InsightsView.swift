import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter

    private var measuredShots: [Shot] { store.shots.filter(\.hasLaunchData) }
    private var chartShots: [Shot] { Array(measuredShots.prefix(20).reversed()) }
    private var tempoRatios: [Double] {
        store.shots.map(\.tempoRatio).filter { $0.isFinite && $0 > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NightRangeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if measuredShots.isEmpty && tempoRatios.isEmpty {
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
                            if !measuredShots.isEmpty {
                                summaryCards
                            }
                            if !tempoRatios.isEmpty {
                                tempoTrend
                            }
                            if !measuredShots.isEmpty {
                                carryTrend
                                clubSummary
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Insights")
        }
    }

    private var tempoTrend: some View {
        let bins = TempoTrend.histogram(tempoRatios)
        let onTargetPercentage = TempoTrend.onTargetPercentage(tempoRatios) ?? 0
        let onTargetCount = bins.first(where: \.isTarget)?.count ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            Text("Tempo trends").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(onTargetPercentage, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(Theme.Palette.ion)
                Text("in the 2.7–3.3:1 target band")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(onTargetCount) of \(tempoRatios.count) swings · tempo is estimated from detected swing phases")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(bins) { bin in
                BarMark(
                    x: .value("Tempo ratio", bin.label),
                    y: .value("Swings", bin.count)
                )
                .foregroundStyle(bin.isTarget ? Theme.Palette.ion : Theme.Palette.plasma.opacity(0.7))
            }
            .chartYAxisLabel("Swings")
            .frame(height: 180)
            .accessibilityLabel("Histogram of swing tempo ratios")
            .accessibilityValue("\(onTargetCount) of \(tempoRatios.count) swings are in the target band")
        }
        .insightPanel()
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

struct TempoHistogramBin: Identifiable {
    let label: String
    let count: Int
    let isTarget: Bool

    var id: String { label }
}

enum TempoTrend {
    static func histogram(_ ratios: [Double]) -> [TempoHistogramBin] {
        let labels = ["<2.2", "2.2–<2.7", "2.7–3.3", ">3.3–3.9", ">3.9"]
        var counts = Array(repeating: 0, count: labels.count)

        for ratio in ratios where ratio.isFinite && ratio > 0 {
            let index: Int
            if ratio < 2.2 {
                index = 0
            } else if ratio < 2.7 {
                index = 1
            } else if ratio <= 3.3 {
                index = 2
            } else if ratio <= 3.9 {
                index = 3
            } else {
                index = 4
            }
            counts[index] += 1
        }

        return labels.enumerated().map { index, label in
            TempoHistogramBin(label: label, count: counts[index], isTarget: index == 2)
        }
    }

    static func onTargetPercentage(_ ratios: [Double]) -> Double? {
        let validRatios = ratios.filter { $0.isFinite && $0 > 0 }
        guard !validRatios.isEmpty else { return nil }
        let inTarget = validRatios.filter { (2.7...3.3).contains($0) }.count
        return Double(inTarget) / Double(validRatios.count)
    }
}

private extension View {
    func insightPanel() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.carbon, in: RoundedRectangle(cornerRadius: 16))
    }
}
