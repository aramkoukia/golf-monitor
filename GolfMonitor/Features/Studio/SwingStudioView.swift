import AVKit
import AVFoundation
import SwiftUI

struct SwingStudioView: View {
    let route: StudioRoute
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var player: AVPlayer?
    @State private var selectedPhase: SwingPhase?
    @State private var playbackTime = 0.0
    @State private var showPose = true
    @State private var playbackObserver: Any?

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
            .onDisappear {
                player?.pause()
                if let playbackObserver, let player {
                    player.removeTimeObserver(playbackObserver)
                }
                playbackObserver = nil
            }
        }
    }

    @ViewBuilder
    private func playerSection(for shot: Shot) -> some View {
        if let player, store.clipURL(for: shot.id) != nil {
            VideoPlayer(player: player)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if let analysis {
                        GeometryReader { geometry in
                            let mapping = AspectFitMapping(
                                viewSize: geometry.size,
                                frameAspect: CGFloat(analysis.frameWidth) / CGFloat(max(analysis.frameHeight, 1))
                            )
                            ZStack {
                                if !analysis.ballTrack.isEmpty {
                                    TrackOverlay(points: analysis.ballTrack, mapping: mapping)
                                }
                                if showPose, let pose = analysis.pose(at: playbackTime),
                                   abs(pose.t - playbackTime) < 0.15 {
                                    BodyPoseOverlay(pose: pose, mapping: mapping)
                                }
                            }
                        }
                        .allowsHitTesting(false)
                        .overlay(alignment: .topTrailing) {
                            if !analysis.poses.isEmpty {
                                Button {
                                    showPose.toggle()
                                } label: {
                                    Label("Pose", systemImage: "figure.stand")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(.black.opacity(0.65), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                                .accessibilityLabel(showPose ? "Hide body pose overlay" : "Show body pose overlay")
                            }
                        }
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
                metric("Carry", shot.hasLaunchData ? formatDistance(yards: shot.carryYards, settings: settings) : "—")
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
                                selectedPhase = marker.phase
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
                                .background(selectedPhase == marker.phase ? Theme.Palette.steel : Theme.Palette.graphite,
                                            in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(marker.phase.title), \(marker.t, format: .number.precision(.fractionLength(2))) seconds")
                            .accessibilityHint("Seeks the video to this estimated swing phase")
                        }
                    }
                }
                if let selectedPhase, let marker = phases.first(where: { $0.phase == selectedPhase }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(marker.phase.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Palette.floodlight)
                        Spacer()
                        Text("Estimated · \(marker.t, format: .number.precision(.fractionLength(2))) s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
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
            Text("Swing measurements").font(.headline)
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
            }
            if let metrics = analysis?.metrics, !metrics.isEmpty {
                ForEach(metrics) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text("\(item.value, specifier: "%.1f") \(item.unit)")
                                .monospacedDigit()
                                .foregroundStyle(Theme.color(for: item.rating))
                        }
                        Text(item.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                Text("Pose measurements are 2D estimates from the video, not 3D joint measurements or coaching diagnoses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if analysis?.insights.isEmpty != false {
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
        let player = AVPlayer(url: url)
        self.player = player
        playbackObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { time in
            guard time.seconds.isFinite else { return }
            playbackTime = time.seconds
        }
    }
}

private struct TrackOverlay: View {
    let points: [TrackPoint]
    let mapping: AspectFitMapping

    var body: some View {
        Canvas { context, _ in
            guard points.count > 1 else { return }
            var path = Path()
            for (index, point) in points.enumerated() {
                let position = mapping.point(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            context.stroke(path, with: .color(Theme.Palette.tracerCore),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct BodyPoseOverlay: View {
    let pose: PoseSample
    let mapping: AspectFitMapping

    var body: some View {
        Canvas { context, _ in
            for (first, second) in BodyJoint.bones {
                guard let a = pose.point(first), let b = pose.point(second) else { continue }
                var path = Path()
                path.move(to: mapping.point(a))
                path.addLine(to: mapping.point(b))
                context.stroke(path, with: .color(Theme.Palette.ion),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            for joint in BodyJoint.allCases {
                guard let point = pose.point(joint) else { continue }
                let center = mapping.point(point)
                let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
                context.fill(dot, with: .color(.white))
            }
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
