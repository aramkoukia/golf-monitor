import SwiftUI

/// The result screen after a recording: slow-motion replay with the tracer,
/// the hero carry number counting up, metric tiles cascading in with their
/// provenance, what the session contained (practice swings / strike) and the
/// next action.
struct ShotRevealView: View {
    var outcome: SessionOutcome
    var feedback: RangeFeedback?
    var onNext: () -> Void
    var onDiscard: () -> Void

    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @State private var revealed = false
    @State private var confirmDiscard = false

    private var featured: FeaturedShot? { outcome.featured }
    private var shot: Shot? { featured?.shot }

    var body: some View {
        ZStack {
            FloodlightBackground(animated: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    media
                    sessionChips
                    if let shot, shot.hasLaunchData {
                        launchHero(shot)
                        launchTiles(shot)
                    } else if let shot {
                        swingOnly(shot)
                    }
                    if let feedback { feedbackCard(feedback) }
                    ForEach(outcome.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.caution)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentCard()
                    }
                    Text("● measured   ◐ estimated (flight model, typical spin for the club)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.dim)
                    actions
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            withAnimation(Theme.Motion.reveal) { revealed = true }
            Haptics.success()
        }
        .confirmationDialog("Discard this recording's shots?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: onDiscard)
        } message: {
            Text("They'll be removed from your library. Videos already saved to Photos stay there.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                CapsLabel(headerEyebrow, color: Theme.Palette.plasma)
                Text(shot?.club.rawValue ?? "Shot")
                    .font(Theme.Font.display)
                    .foregroundStyle(Theme.Palette.floodlight)
            }
            Spacer()
            Text(shot?.cameraView.shortTitle ?? "")
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.mist)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.Palette.graphite, in: Capsule())
        }
    }

    private var headerEyebrow: String {
        guard let shot else { return "Result" }
        if shot.hasLaunchData { return isPersonalBest(shot) ? "New personal best" : "Shot measured" }
        return outcome.struckCount > 0 ? "Strike found" : "Swing analyzed"
    }

    @ViewBuilder
    private var media: some View {
        if let shot, let url = store.clipURL(for: shot.id) {
            ClipLoopPlayer(url: url, analysis: featured?.analysis)
                .aspectRatio(mediaAspect, contentMode: .fit)
                .frame(maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label("1/8 SPEED", systemImage: "slowmo")
                        .font(.system(size: 10, weight: .heavy).width(.condensed))
                        .foregroundStyle(Theme.Palette.floodlight)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(10)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
                .scaleEffect(revealed ? 1 : 0.94)
                .opacity(revealed ? 1 : 0)
                .frame(maxWidth: .infinity)
        } else if let image = featured?.tracerImage ?? featured?.thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        }
    }

    private var mediaAspect: CGFloat {
        guard let a = featured?.analysis, a.frameHeight > 0 else { return 9.0 / 16.0 }
        return CGFloat(a.frameWidth) / CGFloat(a.frameHeight)
    }

    private var sessionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(icon: "figure.golf", text: "\(outcome.practiceSwings) practice swing\(outcome.practiceSwings == 1 ? "" : "s")",
                     color: Theme.Palette.mist)
                chip(icon: outcome.struckCount > 0 ? "checkmark.seal.fill" : "questionmark.circle",
                     text: outcome.struckCount > 0 ? "\(outcome.struckCount) strike\(outcome.struckCount == 1 ? "" : "s") found" : "No strike found",
                     color: outcome.struckCount > 0 ? Theme.Palette.ion : Theme.Palette.caution)
                if outcome.savedToPhotos {
                    chip(icon: "photo.on.rectangle.angled", text: "Saved to Photos", color: Theme.Palette.ion)
                }
            }
        }
        .opacity(revealed ? 1 : 0)
    }

    private func chip(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.Palette.carbon, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
    }

    private func launchHero(_ shot: Shot) -> some View {
        let best = isPersonalBest(shot)
        return VStack(spacing: 14) {
            HeroNumber(label: "Carry", value: settings.distanceValue(yards: shot.carryYards),
                       unit: settings.distanceUnitLabel, size: 112, provenance: .modeled,
                       highlight: best ? Theme.Palette.apexViolet : nil)
            HStack(spacing: 0) {
                HeroNumber(label: "Ball speed", value: settings.speedValue(mph: shot.ballSpeedMph),
                           unit: settings.speedUnitLabel, size: 50, provenance: .measured)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Theme.Palette.hairlineStrong).frame(width: 1, height: 54)
                HeroNumber(label: "Launch", value: shot.launchAngleDeg, unit: "°", digits: 1, size: 50,
                           provenance: .measured)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .contentCard(cornerRadius: Theme.Radius.l, elevated: true)
        .overlay(alignment: .topTrailing) {
            if best {
                Label("PB", systemImage: "crown.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Theme.Palette.apexViolet)
                    .padding(12)
            }
        }
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 20)
    }

    private func launchTiles(_ shot: Shot) -> some View {
        let tiles: [(String, Double?, String, Int, Provenance)] = [
            ("Club speed", shot.clubSpeedMph > 0 ? settings.speedValue(mph: shot.clubSpeedMph) : nil, settings.speedUnitLabel, 0, .modeled),
            ("Apex", settings.distanceValue(yards: shot.apexYards), settings.distanceUnitLabel, 0, .modeled),
            ("Hang time", shot.hangTimeS, "s", 1, .modeled),
            ("Descent", shot.descentAngleDeg, "°", 0, .modeled),
            ("Tempo", shot.tempoRatio > 0 ? shot.tempoRatio : nil, ": 1", 1, .measured),
            ("Backswing", shot.backswingTimeS, "s", 2, .measured),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                MetricTile(label: tile.0, value: tile.1, unit: tile.2, digits: tile.3, provenance: tile.4)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 18)
                    .animation(Theme.Motion.reveal.delay(0.15 + Double(index) * 0.06), value: revealed)
            }
        }
    }

    private func swingOnly(_ shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HeroNumber(label: "Tempo", value: shot.tempoRatio > 0 ? shot.tempoRatio : nil, unit: ": 1",
                           digits: 1, size: 84, provenance: .measured)
                Spacer()
            }
            HStack(spacing: 10) {
                MetricTile(label: "Backswing", value: shot.backswingTimeS, unit: "s", digits: 2)
                MetricTile(label: "Downswing", value: shot.downswingTimeS, unit: "s", digits: 2)
            }
            if let reason = featured?.metricsError {
                Label(reason, systemImage: "info.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(shot.cameraView == .downTheLine
                 ? "Down-the-line view analyzes your swing. Switch to face-on for ball speed and carry."
                 : "For ball numbers, keep the teed ball in view (the reticle turns green) and hit it while recording.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: Theme.Radius.l, elevated: true)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 20)
    }

    private func feedbackCard(_ feedback: RangeFeedback) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feedback.isSuccess ? "target" : "scope")
                .font(.title2)
                .foregroundStyle(feedback.isSuccess ? Theme.Palette.ion : Theme.Palette.plasma)
            VStack(alignment: .leading, spacing: 3) {
                Text(feedback.headline).font(Theme.Font.headline).foregroundStyle(Theme.Palette.floodlight)
                if !feedback.detail.isEmpty {
                    Text(feedback.detail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.mist)
                }
            }
            Spacer()
            if let points = feedback.points {
                Text("+\(points)")
                    .font(Theme.Font.metric(28))
                    .foregroundStyle(Theme.Palette.ion)
            }
        }
        .padding(16)
        .contentCard()
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onNext) {
                Label("Next shot", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(PlasmaButtonStyle())
            HStack(spacing: 10) {
                if let shot {
                    Button {
                        router.openStudio(shot.id)
                    } label: {
                        Label("Swing Studio", systemImage: "play.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.top, 6)
    }

    private func isPersonalBest(_ shot: Shot) -> Bool {
        let others = store.shots(for: shot.club).filter { $0.id != shot.id && $0.hasLaunchData }
        guard !others.isEmpty else { return false }
        return shot.carryYards > (others.map(\.carryYards).max() ?? .infinity)
    }
}
