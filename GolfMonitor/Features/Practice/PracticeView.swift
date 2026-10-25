import SwiftUI

struct PracticeView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: SettingsStore
    @State private var completedShots = 0
    @State private var challengePoints = 0

    var body: some View {
        NavigationStack {
            ZStack {
                NightRangeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        challengeCard
                        recentPractice
                        drillCard
                    }
                    .padding()
                }
            }
            .navigationTitle("Practice")
        }
    }

    private var challengeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CARRY CHALLENGE", systemImage: "scope")
                .font(.caption.bold())
                .foregroundStyle(Theme.Palette.plasma)
            Text("Land within \(formatDistance(yards: 15, settings: settings)) of \(formatDistance(yards: 150, settings: settings)).")
                .font(.title3.bold())
            Text("Five shots. Each measured shot inside the target earns 10 points.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text("THIS CHALLENGE")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(completedShots)/5 shots · \(challengePoints) pts")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Button {
                startChallenge()
            } label: {
                Label("Start challenge in Range", systemImage: "figure.golf")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.plasma)
        }
        .practicePanel()
    }

    private var recentPractice: some View {
        let shots = store.shots.filter { $0.practice != nil }
        let scoredShots = shots.filter { $0.practice?.points != nil }
        let points = scoredShots.compactMap { $0.practice?.points }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Practice history").font(.headline)
            HStack {
                practiceStat("PRACTICE SHOTS", "\(shots.count)")
                practiceStat("POINTS", "\(points)")
                practiceStat("LAST CLUB", shots.first?.club.shortName ?? "—")
            }
            if let last = shots.first {
                Text("Last practice shot · \(last.club.rawValue) · \(last.hasLaunchData ? formatDistance(yards: last.carryYards, settings: settings) : "carry not measured")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Shots saved from a challenge are collected here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .practicePanel()
    }

    private var drillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick drill").font(.headline)
            Text("Tempo check")
                .font(.subheadline.weight(.semibold))
            Text("Record five swings with the same club. Compare your tempo ratios in Insights; a steady rhythm is more useful than chasing one perfect swing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Insights", systemImage: "chart.xyaxis.line") {
                router.tab = .insights
            }
            .buttonStyle(.bordered)
        }
        .practicePanel()
    }

    private func practiceStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startChallenge() {
        completedShots = 0
        challengePoints = 0
        let completedBinding = $completedShots
        let pointsBinding = $challengePoints
        let targetYards = 150.0
        let context = RangeSessionContext(
            title: "Carry Challenge",
            subtitle: "5 shots · target \(formatDistance(yards: targetYards, settings: settings))",
            gameID: "carry-challenge-150",
            currentTarget: {
                RangeTarget(label: "TARGET \(formatDistance(yards: targetYards, settings: settings))",
                            carryYards: targetYards, toleranceYards: 15)
            },
            onShot: { shot in
                completedBinding.wrappedValue += 1
                guard shot.hasLaunchData else {
                    return RangeFeedback(
                        headline: completedBinding.wrappedValue >= 5 ? "Challenge complete" : "Shot saved",
                        detail: "Carry was not measured, so this shot did not score."
                    )
                }
                let hit = abs(shot.carryYards - targetYards) <= 15
                let earned = hit ? 10 : 0
                pointsBinding.wrappedValue += earned
                let detail = "Carry \(formatDistance(yards: shot.carryYards, settings: settings)) · \(earned) points"
                return RangeFeedback(
                    headline: completedBinding.wrappedValue >= 5
                        ? "Challenge complete"
                        : (hit ? "On target" : "Keep working"),
                    detail: detail,
                    points: earned,
                    isSuccess: hit
                )
            },
            isFinished: { completedBinding.wrappedValue >= 5 }
        )
        router.startPractice(context)
    }
}

private extension View {
    func practicePanel() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.carbon, in: RoundedRectangle(cornerRadius: 16))
    }
}
