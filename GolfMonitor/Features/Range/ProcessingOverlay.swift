import SwiftUI

/// Full-screen "analyzing" state: a progress ring with a comet head and the
/// pipeline's four steps checking off as they complete.
struct ProcessingOverlay: View {
    var progress: ProcessingProgress
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Theme.Palette.void.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                ProgressRing(fraction: progress.fraction)
                    .frame(width: 168, height: 168)
                    .overlay {
                        VStack(spacing: 2) {
                            Text("\(Int((progress.fraction * 100).rounded()))")
                                .font(Theme.Font.hero(54))
                                .monospacedDigit()
                                .foregroundStyle(Theme.Palette.floodlight)
                                .contentTransition(.numericText(value: progress.fraction))
                            CapsLabel("percent", color: Theme.Palette.mist)
                        }
                    }

                VStack(spacing: 6) {
                    Text("Analyzing on your iPhone")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.Palette.floodlight)
                    Text(progress.detail)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.mist)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ProcessingProgress.Step.allCases, id: \.self) { step in
                        StepRow(title: step.title, state: state(of: step))
                    }
                }
                .padding(18)
                .frame(maxWidth: 320, alignment: .leading)
                .contentCard(cornerRadius: Theme.Radius.l)

                Spacer()
                Button("Cancel", systemImage: "xmark", action: onCancel)
                    .buttonStyle(GlassButtonStyle())
                    .padding(.bottom, 24)
            }
            .animation(Theme.Motion.smooth, value: progress.step)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Analyzing, \(Int(progress.fraction * 100)) percent. \(progress.detail)")
    }

    private func state(of step: ProcessingProgress.Step) -> StepRow.State {
        if step < progress.step { return .done }
        return step == progress.step ? .active : .pending
    }
}

private struct StepRow: View {
    enum State { case pending, active, done }
    var title: String
    var state: State

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.Palette.steel, lineWidth: 2).frame(width: 22, height: 22)
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Palette.ion)
                        .transition(.scale.combined(with: .opacity))
                case .active:
                    ProgressView().controlSize(.small).tint(Theme.Palette.plasma)
                case .pending:
                    EmptyView()
                }
            }
            .frame(width: 24, height: 24)
            Text(title)
                .font(Theme.Font.headline)
                .foregroundStyle(state == .pending ? Theme.Palette.dim : Theme.Palette.floodlight)
        }
    }
}

/// Plasma arc with a glowing head.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 10

    var body: some View {
        let f = min(max(fraction, 0.001), 1)
        ZStack {
            Circle().stroke(Theme.Palette.steel.opacity(0.7), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: f)
                .stroke(AngularGradient(colors: [Theme.Palette.plasma.opacity(0.1), Theme.Palette.plasma,
                                                 Theme.Palette.tracerCore],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * f)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .glow(Theme.Palette.plasma, radius: 10, opacity: 0.5)
        }
        .animation(Theme.Motion.smooth, value: fraction)
    }
}
