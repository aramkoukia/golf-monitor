import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @State private var sessionTrendMetric: SessionTrendMetric = .ballSpeed

    private var measuredShots: [Shot] { store.shots.filter(\.hasLaunchData) }
    private var chartShots: [Shot] { Array(measuredShots.prefix(20).reversed()) }
    private var tempoRatios: [Double] {
        store.shots.map(\.tempoRatio).filter { $0.isFinite && $0 > 0 }
    }
    private var recentTrendSession: PracticeSession? {
        store.sessions.first { session in
            SessionTrendMetric.allCases.contains { metric in
                SessionTrend.points(shots: store.shots, sessionID: session.id, metric: metric).count >= 2
            }
        }
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
                            if let recentTrendSession {
                                sessionTrend(recentTrendSession)
                            }
                            if !measuredShots.isEmpty {
                                carryTrend
                                clubGapping
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

    private func sessionTrend(_ session: PracticeSession) -> some View {
        let points = SessionTrend.points(shots: store.shots, sessionID: session.id,
                                         metric: sessionTrendMetric)
        let average = points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Within-session trend").font(.headline)
            Text(session.title.isEmpty ? session.start.formatted(date: .abbreviated, time: .shortened) : session.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Metric", selection: $sessionTrendMetric) {
                ForEach(SessionTrendMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            if points.count < 2 {
                Text("Not enough \(sessionTrendMetric.title.lowercased()) measurements in this session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if let average {
                    Text("Average \(sessionTrendMetric.title.lowercased()): \(sessionTrendMetric.format(average)) · \(points.count) shots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Chart(points) { point in
                    LineMark(
                        x: .value("Shot", point.shotNumber),
                        y: .value(sessionTrendMetric.title, point.value)
                    )
                    .foregroundStyle(Theme.Palette.plasma)
                    .interpolationMethod(.linear)
                    PointMark(
                        x: .value("Shot", point.shotNumber),
                        y: .value(sessionTrendMetric.title, point.value)
                    )
                    .foregroundStyle(Theme.Palette.tracerCore)
                }
                .chartXAxisLabel("Shot number")
                .chartYAxisLabel(sessionTrendMetric.unit)
                .frame(height: 180)
            }
            Text("Descriptive session variation only; this does not diagnose fatigue or explain why values changed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    private var clubGapping: some View {
        let rows = ClubGapping.rows(Club.allCases.compactMap { club -> ClubGapping.Measurement? in
            let averages = store.averages(for: club)
            guard averages.count > 0 else { return nil }
            return ClubGapping.Measurement(club: club, count: averages.count,
                                           ballSpeedMph: averages.ballSpeedMph,
                                           carryYards: averages.carryYards)
        })

        return VStack(alignment: .leading, spacing: 12) {
            Text("Club gapping").font(.headline)
            Text("Average ball speed is measured. Carry is a flight-model estimate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if rows.count < 2 {
                Text("Record measured shots with at least two clubs to compare gaps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Ball speed", row.ballSpeedMph),
                        y: .value("Club", row.club.shortName)
                    )
                    .foregroundStyle(Theme.Palette.ion)
                }
                .chartXScale(domain: 0...(max(rows.map(\.ballSpeedMph).max() ?? 1, 1) * 1.15))
                .chartXAxisLabel("Ball speed (mph)")
                .chartYScale(domain: Array(rows.map(\.club.shortName).reversed()))
                .frame(height: CGFloat(rows.count * 34 + 12))

                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(row.club.shortName)
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 34, alignment: .leading)
                            Text("\(Int(settings.speedValue(mph: row.ballSpeedMph).rounded())) \(settings.speedUnitLabel)")
                                .monospacedDigit()
                            Text("~\(formatDistance(yards: row.carryYards, settings: settings))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Text("\(row.count) \(row.count == 1 ? "shot" : "shots")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let gap = row.ballSpeedGapMph {
                                HStack(spacing: 8) {
                                    Text("\(gap >= 0 ? "+" : "")\(Int(settings.speedValue(mph: gap).rounded())) \(settings.speedUnitLabel) vs prev")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.Palette.ion)
                                    if let carryGap = row.carryGapYards {
                                        let sign = carryGap >= 0 ? "+" : "−"
                                        Text("\(sign)~\(formatDistance(yards: abs(carryGap), settings: settings))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .font(.subheadline)
                }
                Text("Gaps compare each club with the previous club shown. Small samples and estimated carry can make apparent gaps unreliable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

struct ClubGapRow: Identifiable {
    let club: Club
    let count: Int
    let ballSpeedMph: Double
    let carryYards: Double
    let ballSpeedGapMph: Double?
    let carryGapYards: Double?

    var id: Club { club }
}

enum ClubGapping {
    struct Measurement {
        let club: Club
        let count: Int
        let ballSpeedMph: Double
        let carryYards: Double
    }

    static func rows(_ measurements: [Measurement]) -> [ClubGapRow] {
        let valid = measurements
            .filter {
                $0.count > 0 && $0.ballSpeedMph.isFinite && $0.ballSpeedMph > 0 &&
                $0.carryYards.isFinite && $0.carryYards > 0
            }
            .sorted { $0.club.bagOrder < $1.club.bagOrder }

        return valid.enumerated().map { index, measurement in
            let previous = index > 0 ? valid[index - 1] : nil
            return ClubGapRow(
                club: measurement.club,
                count: measurement.count,
                ballSpeedMph: measurement.ballSpeedMph,
                carryYards: measurement.carryYards,
                ballSpeedGapMph: previous.map { $0.ballSpeedMph - measurement.ballSpeedMph },
                carryGapYards: previous.map { $0.carryYards - measurement.carryYards }
            )
        }
    }
}

enum SessionTrendMetric: String, CaseIterable, Identifiable {
    case ballSpeed
    case launch
    case tempo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ballSpeed: return "Ball speed"
        case .launch: return "Launch"
        case .tempo: return "Tempo"
        }
    }

    var unit: String {
        switch self {
        case .ballSpeed: return "mph"
        case .launch: return "°"
        case .tempo: return ":1"
        }
    }

    func value(from shot: Shot) -> Double? {
        let value: Double
        switch self {
        case .ballSpeed:
            value = shot.ballSpeedMph
        case .launch:
            guard shot.hasLaunchData, shot.launchAngleDeg.isFinite else { return nil }
            value = shot.launchAngleDeg
        case .tempo:
            value = shot.tempoRatio
        }
        guard value.isFinite else { return nil }
        switch self {
        case .launch:
            guard shot.hasLaunchData else { return nil }
        case .ballSpeed, .tempo:
            guard value > 0 else { return nil }
        }
        return value
    }

    func format(_ value: Double) -> String {
        String(format: "%.1f %@", value, unit)
    }
}

struct SessionTrendPoint: Identifiable {
    let shotNumber: Int
    let value: Double

    var id: Int { shotNumber }
}

enum SessionTrend {
    static func points(shots: [Shot], sessionID: UUID, metric: SessionTrendMetric) -> [SessionTrendPoint] {
        shots
            .filter { $0.sessionID == sessionID }
            .sorted { $0.date < $1.date }
            .enumerated()
            .compactMap { index, shot in
                guard let value = metric.value(from: shot) else { return nil }
                return SessionTrendPoint(shotNumber: index + 1, value: value)
            }
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
