import AVKit
import AVFoundation
import SwiftUI

struct SwingStudioView: View {
    let route: StudioRoute
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var player: AVPlayer?

    private var shot: Shot? { store.shot(id: route.shotID) }
    private var analysis: SwingAnalysis? { store.analysis(for: route.shotID) }
    private var comparison: Shot? { route.compareShotID.flatMap(store.shot(id:)) }

    var body: some View {
        NavigationStack {
            ZStack {
                NightRangeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let shot {
                            playerSection(for: shot)
                            shotMetrics(shot)
                            phaseSection
                            coachingSection
                            if let comparison { compareSection(shot, comparison) }
                        } else {
                            ContentUnavailableView("Shot unavailable", systemImage: "film",
                                                   description: Text("This shot may have been deleted."))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Swing Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: loadPlayer)
            .onDisappear { player?.pause() }
        }
    }

    @ViewBuilder
    private func playerSection(for shot: Shot) -> some View {
        if let player, store.clipURL(for: shot.id) != nil {
            VideoPlayer(player: player)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if let analysis, !analysis.ballTrack.isEmpty {
                        TrackOverlay(points: analysis.ballTrack)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "video.slash").font(.largeTitle)
                Text(shot.hasMedia ? "Clip unavailable" : "No swing clip saved")
                    .font(.headline)
                Text("Recorded shots with saved media can be reviewed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(Theme.Palette.carbon, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func shotMetrics(_ shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(shot.club.rawValue).font(.headline)
                Spacer()
                Text(shot.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("Ball speed", formatSpeed(mph: shot.ballSpeedMph, settings: settings))
                metric("Carry", formatDistance(yards: shot.carryYards, settings: settings))
                metric("Club speed", formatSpeed(mph: shot.clubSpeedMph, settings: settings))
                metric("Launch", shot.hasLaunchData ? String(format: "%.1f°", shot.launchAngleDeg) : "—")
                metric("Tempo", formatTempo(shot.tempoRatio))
                metric("Swing score", shot.swingScore.map(String.init) ?? "—")
            }
            if let analysis {
                Text(analysis.pipeline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .studioPanel()
    }

    private var phaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swing phases").font(.headline)
            if let player, let phases = analysis?.phases, !phases.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(phases) { marker in
                            Button {
                                player.seek(to: CMTime(seconds: marker.t, preferredTimescale: 600))
                                player.play()
                            } label: {
                                VStack(spacing: 3) {
                                    Text(marker.phase.shortTitle)
                                        .font(.caption.bold())
                                    Text(marker.t, format: .number.precision(.fractionLength(2)))
                                        .font(.caption2.monospacedDigit())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.Palette.graphite, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("Phase markers are not available for this clip.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .studioPanel()
    }

    private var coachingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analysis").font(.headline)
            if let insights = analysis?.insights, !insights.isEmpty {
                ForEach(insights) { insight in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(insight.title).font(.subheadline.weight(.semibold))
                        Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                        if let drill = insight.drill {
                            Text("Drill: \(drill)").font(.caption).foregroundStyle(Theme.Palette.ion)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let metrics = analysis?.metrics, !metrics.isEmpty {
                ForEach(metrics) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text("\(item.value, specifier: "%.1f") \(item.unit)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.color(for: item.rating))
                    }
                    .font(.subheadline)
                }
            } else {
                Text("No coaching observations were generated for this swing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .studioPanel()
    }

    private func compareSection(_ first: Shot, _ second: Shot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shot comparison").font(.headline)
            comparisonRow("Carry", first.carryYards, second.carryYards, suffix: "yd")
            comparisonRow("Ball speed", first.ballSpeedMph, second.ballSpeedMph, suffix: "mph")
            comparisonRow("Tempo", first.tempoRatio, second.tempoRatio, suffix: ":1")
            Text("Compared with \(second.club.rawValue) · \(second.date.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .studioPanel()
    }

    private func comparisonRow(_ label: String, _ first: Double, _ second: Double, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(first, specifier: "%.1f") \(suffix)")
            Text("vs").foregroundStyle(.secondary)
            Text("\(second, specifier: "%.1f") \(suffix)")
        }
        .font(.subheadline.monospacedDigit())
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadPlayer() {
        guard player == nil, let url = store.clipURL(for: route.shotID) else { return }
        player = AVPlayer(url: url)
    }
}

private struct TrackOverlay: View {
    let points: [TrackPoint]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard points.count > 1 else { return }
                var path = Path()
                for (index, point) in points.enumerated() {
                    let position = CGPoint(x: CGFloat(point.x) * size.width,
                                           y: CGFloat(point.y) * size.height)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                context.stroke(path, with: .color(Theme.Palette.tracerCore),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private extension View {
    func studioPanel() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.carbon, in: RoundedRectangle(cornerRadius: 16))
    }
}
