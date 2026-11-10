import AVFoundation
import SwiftUI

/// First-run onboarding: how to set up the phone, the one-button routine
/// (also on Apple Watch), and on-device privacy with the two choices that
/// matter (swing side, saving to Photos). Ends by asking for the camera.
struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var page = 0

    var body: some View {
        ZStack {
            FloodlightBackground()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    setupPage.tag(0)
                    routinePage.tag(1)
                    privacyPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(Theme.Motion.smooth, value: page)

                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i == page ? Theme.Palette.plasma : Theme.Palette.steel)
                            .frame(width: i == page ? 26 : 8, height: 8)
                    }
                }
                .animation(Theme.Motion.snappy, value: page)
                .padding(.bottom, 18)

                Button(page < 2 ? "Next" : "Let's go") {
                    if page < 2 {
                        page += 1
                    } else {
                        finish()
                    }
                }
                .buttonStyle(PlasmaButtonStyle())
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: Pages

    private var setupPage: some View {
        page(eyebrow: "Set up", title: "Your iPhone is the launch monitor",
             body: "Put the phone on a tripod side-on to the target line, 2–3 m from the ball, lens at ball height. Keep the ball in view with open space in front of it.") {
            SetupIllustration()
        }
    }

    private var routinePage: some View {
        page(eyebrow: "One button", title: "Start, swing, stop",
             body: "Press record once, then take your time: set up, make practice swings, hit the ball, press stop. GolfMonitor finds the real strike, measures it and keeps the clip.") {
            VStack(spacing: 12) {
                routineStep("record.circle.fill", "Start", "On the phone or your Apple Watch", Theme.Palette.plasma)
                routineStep("figure.golf", "Practice swings", "As many as you like — they're ignored", Theme.Palette.mist)
                routineStep("circle.dotted.circle", "Hit the ball", "The ball leaving the tee marks the shot", Theme.Palette.ion)
                routineStep("stop.circle.fill", "Stop", "Numbers on your screen and your wrist", Theme.Palette.signalRed)
            }
        }
    }

    private var privacyPage: some View {
        page(eyebrow: "Private by design", title: "Everything stays on your iPhone",
             body: "Ball detection, swing analysis and the flight model all run on the device. No account, no server, no upload.") {
            VStack(spacing: 12) {
                Picker("Swing", selection: $settings.handedness) {
                    ForEach(Handedness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $settings.saveShotsToPhotos) {
                    Label("Save shot videos to Photos", systemImage: "photo.on.rectangle.angled")
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.floodlight)
                }
                .tint(Theme.Palette.plasma)
            }
            .padding(16)
            .contentCard(cornerRadius: Theme.Radius.l)
        }
    }

    private func page<Art: View>(eyebrow: String, title: String, body: String,
                                 @ViewBuilder art: () -> Art) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 12)
            art()
                .frame(maxWidth: .infinity)
            Spacer(minLength: 12)
            CapsLabel(eyebrow, color: Theme.Palette.plasma)
            Text(title)
                .font(Theme.Font.display)
                .foregroundStyle(Theme.Palette.floodlight)
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private func routineStep(_ icon: String, _ title: String, _ detail: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.headline).foregroundStyle(Theme.Palette.floodlight)
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.mist)
            }
            Spacer()
        }
        .padding(14)
        .contentCard(cornerRadius: Theme.Radius.m)
    }

    private func finish() {
        Haptics.success()
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { settings.hasCompletedOnboarding = true }
        }
    }
}

/// Tripod, phone and ball with an animated Plasma flight arc.
private struct SetupIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
            let t = reduceMotion ? 1 : min(1, cycle / 1.6)
            drawing(progress: CGFloat(1 - pow(1 - t, 2.2)))
        }
        .frame(height: 220)
        .accessibilityLabel("Phone on a tripod beside the ball, filming the ball flight")
    }

    private func drawing(progress: CGFloat) -> some View {
        Canvas { context, size in
            let ground = size.height * 0.78
            var turf = Path()
            turf.move(to: CGPoint(x: 0, y: ground))
            turf.addLine(to: CGPoint(x: size.width, y: ground))
            context.stroke(turf, with: .color(Theme.Palette.turfLit), lineWidth: 2)

            // Tripod + phone on the left.
            let tx = size.width * 0.16
            var legs = Path()
            legs.move(to: CGPoint(x: tx, y: ground - 70))
            legs.addLine(to: CGPoint(x: tx - 22, y: ground))
            legs.move(to: CGPoint(x: tx, y: ground - 70))
            legs.addLine(to: CGPoint(x: tx + 22, y: ground))
            legs.move(to: CGPoint(x: tx, y: ground - 70))
            legs.addLine(to: CGPoint(x: tx, y: ground))
            context.stroke(legs, with: .color(Theme.Palette.mist), lineWidth: 2)
            context.fill(Path(roundedRect: CGRect(x: tx - 10, y: ground - 100, width: 20, height: 34), cornerRadius: 4),
                         with: .color(Theme.Palette.floodlight))

            // Ball and flight.
            let ball = CGPoint(x: size.width * 0.42, y: ground - 5)
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 5, y: ball.y - 5, width: 10, height: 10)),
                         with: .color(.white))
            var arc = Path()
            arc.move(to: ball)
            arc.addQuadCurve(to: CGPoint(x: size.width * 0.98, y: ground - 20),
                             control: CGPoint(x: size.width * 0.78, y: size.height * 0.02))
            let trimmed = arc.trimmedPath(from: 0, to: progress)
            var glow = context
            glow.addFilter(.blur(radius: 6))
            glow.stroke(trimmed, with: .color(Theme.Palette.plasma), lineWidth: 8)
            context.stroke(trimmed, with: .color(Theme.Palette.plasma), lineWidth: 3)
            context.stroke(trimmed, with: .color(Theme.Palette.tracerCore), lineWidth: 1)

            // Camera's field of view.
            var fov = Path()
            fov.move(to: CGPoint(x: tx + 10, y: ground - 84))
            fov.addLine(to: CGPoint(x: size.width * 0.72, y: size.height * 0.1))
            fov.move(to: CGPoint(x: tx + 10, y: ground - 84))
            fov.addLine(to: CGPoint(x: size.width * 0.72, y: ground))
            context.stroke(fov, with: .color(Theme.Palette.ion.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
        }
    }
}
