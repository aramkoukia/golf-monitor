import SwiftUI
import UIKit

/// Range tab: full-bleed live camera with a thin glass HUD. One button runs
/// the whole routine — start, set up, practice swings, hit, stop — and the
/// Apple Watch drives exactly the same controls.
///
/// Debug deep links: `-gm.autostart [seconds]` records and analyzes the
/// Simulator's demo swing hands-free.
struct RangeView: View {
    @EnvironmentObject private var session: RangeSessionController
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var watch: WatchLinkStatus
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: ShotStore
    @State private var notice: String?

    var body: some View {
        ZStack {
            CameraPreviewView(layer: camera.previewLayer)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                           .init(color: .clear, location: 0.22),
                                           .init(color: .clear, location: 0.62),
                                           .init(color: .black.opacity(0.75), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

            if camera.status.isLive {
                BallLockOverlay(snapshot: session.scene, isRecording: session.phase.isRecording)
                    .ignoresSafeArea()
            } else {
                cameraUnavailable
            }

            if session.phase.isRecording { RecordingVignette() }

            hud(club: $session.club)

            switch session.phase {
            case .processing:
                ProcessingOverlay(progress: session.progress) { session.cancel() }
                    .transition(.opacity)
            case .review:
                if let outcome = session.outcome {
                    ShotRevealView(outcome: outcome, feedback: session.feedback,
                                   onNext: { session.dismissResult() },
                                   onDiscard: {
                                       store.delete(ids: outcome.shots.map(\.id))
                                       session.dismissResult()
                                   })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .failed(let reason):
                failure(reason)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            default:
                EmptyView()
            }
        }
        .animation(Theme.Motion.smooth, value: session.phase)
        .statusBarHidden(session.phase.isRecording)
        .sensoryFeedback(.success, trigger: session.live.shots) { old, new in new > old }
        .onChange(of: session.lastRejection) { _, reason in
            guard let reason else { return }
            withAnimation { notice = reason }
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation { notice = nil }
        }
    }

    // MARK: HUD

    private func hud(club: Binding<Club>) -> some View {
        VStack(spacing: 12) {
            RangeTopBar(status: camera.status, format: camera.format,
                        isRecording: session.phase.isRecording, watch: watch)
            if !router.rangeContext.isFree { practiceBanner }
            if case .recording(let startedAt) = session.phase {
                RecordingClock(startedAt: startedAt, limit: settings.maxRecordingSeconds)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if camera.status.isLive, session.phase == .idle {
                readinessHint
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.floodlight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassCapsule(tint: Theme.Palette.caution, clear: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            RoutineStrip(isRecording: session.phase.isRecording, swings: session.live.swings,
                         shots: session.live.shots, ballLocked: session.scene.isBallLocked)
            controls(club: club)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func controls(club: Binding<Club>) -> some View {
        HStack(alignment: .center) {
            ClubMenuChip(club: club)
                .disabled(session.phase.isRecording)
                .opacity(session.phase.isRecording ? 0.4 : 1)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RecordButton(isRecording: session.phase.isRecording,
                             isEnabled: session.phase.isRecording || (camera.isReadyToRecord && session.phase == .idle),
                             isReady: session.readiness.isReady && camera.isReadyToRecord && session.phase == .idle,
                             limitFraction: limitFraction(at: context.date)) {
                    if session.phase.isRecording {
                        session.stop(origin: .phone)
                    } else {
                        session.start(origin: .phone)
                    }
                }
            }
            Spacer()
            CameraViewPicker(view: $settings.cameraView)
                .disabled(session.phase.isRecording)
                .opacity(session.phase.isRecording ? 0.4 : 1)
        }
        .padding(.horizontal, 8)
    }

    private func limitFraction(at date: Date) -> Double {
        guard case .recording(let startedAt) = session.phase else { return 0 }
        return min(1, date.timeIntervalSince(startedAt) / max(settings.maxRecordingSeconds, 1))
    }

    /// Whether a recording started now is likely to be caught and measured.
    private var readinessHint: some View {
        let readiness = session.readiness
        let (text, icon, color): (String, String, Color) = switch readiness {
        case .ready: ("Ready to swing — ball locked with room to fly", "checkmark.circle.fill", Theme.Palette.ion)
        case .readySwingOnly: ("Ready — down the line: swing analysis", "checkmark.circle.fill", Theme.Palette.ion)
        case .noBall: ("Tee a ball in view to measure flight", "viewfinder", Theme.Palette.floodlight)
        case .ballAtEdge: ("Ball too close to the frame edge — give it room to fly", "arrow.left.and.right",
                           Theme.Palette.caution)
        case .tooDark: ("Too dark for the \(settings.shutterMode.title) shutter — add light or set Shutter to Auto",
                        "sun.min", Theme.Palette.caution)
        case .phoneMoved: ("Phone moved — step back so the ball re-locks", "exclamationmark.arrow.triangle.2.circlepath",
                           Theme.Palette.caution)
        }
        return Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCapsule()
            .contentTransition(.opacity)
            .animation(Theme.Motion.snappy, value: readiness)
            .accessibilityLabel(readiness.isReady ? "Ready to swing" : text)
    }

    private var practiceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "target").foregroundStyle(Theme.Palette.plasma)
            VStack(alignment: .leading, spacing: 1) {
                CapsLabel(router.rangeContext.title, color: Theme.Palette.plasma)
                Text(router.rangeContext.currentTarget()?.label ?? router.rangeContext.subtitle)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.floodlight)
            }
            Spacer()
            Button("End") {
                router.rangeContext.onFinish()
                router.endPractice()
            }
            .font(.subheadline.bold())
            .foregroundStyle(Theme.Palette.floodlight)
        }
        .padding(12)
        .glassCard(cornerRadius: 18, clear: true)
    }

    // MARK: States

    private var cameraUnavailable: some View {
        VStack(spacing: 14) {
            if camera.status == .starting || camera.status == .idle {
                ProgressView().controlSize(.large).tint(Theme.Palette.plasma)
                Text("Starting the camera…")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.mist)
            } else {
                Image(systemName: camera.status == .denied ? "video.slash.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Palette.caution)
                Text(unavailableTitle)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.floodlight)
                    .multilineTextAlignment(.center)
                if camera.status == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PlasmaButtonStyle())
                    .frame(maxWidth: 240)
                } else {
                    Button("Try again") { camera.start() }
                        .buttonStyle(PlasmaButtonStyle())
                        .frame(maxWidth: 240)
                }
            }
        }
        .padding(28)
    }

    private var unavailableTitle: String {
        switch camera.status {
        case .denied: return "GolfMonitor needs the camera to record your swing"
        case .interrupted: return "The camera is being used by another app"
        case .failed(let reason): return reason
        default: return "Camera unavailable"
        }
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Theme.Palette.caution)
            Text("Couldn't analyze that one")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.Palette.floodlight)
            Text(reason)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.mist)
                .multilineTextAlignment(.center)
            Button("Try again") { session.dismissResult() }
                .buttonStyle(PlasmaButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 360)
        .contentCard(cornerRadius: Theme.Radius.l, elevated: true)
        .padding(24)
    }
}
