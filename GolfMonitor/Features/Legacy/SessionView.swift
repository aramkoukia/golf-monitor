import SwiftUI
import AVFoundation
import UIKit
import Combine

// Range tab's live camera, capture controls and shot review.

// MARK: - Session view

struct SessionView: View {
    @StateObject private var camera = CameraManager()
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter

    private enum Phase { case idle, countdown, recording, processing, result }
    private static let acceptedBallDistanceMeters = 0.5...2.0

    @State private var phase: Phase = .idle
    @State private var countdownValue = 5
    @AppStorage("golfmonitor.countdownSeconds") private var countdownSeconds = 5
    @AppStorage("golfmonitor.clipSeconds") private var clipSeconds = 3
    @State private var selectedClub: Club = Club(
        rawValue: UserDefaults.standard.string(forKey: "golfmonitor.lastClub") ?? ""
    ) ?? .driver
    @State private var metrics: ShotMetrics?
    @State private var analysisOutput: AnalysisOutput?
    @State private var analysisRequest: AnalysisRequest?
    @State private var capturedClipURL: URL?
    @State private var savedShotID: UUID?
    @State private var analysisTask: Task<Void, Never>?
    @State private var practiceFeedback: RangeFeedback?
    @State private var tracerImage: UIImage?
    @State private var processingStatus = "Analyzing frames…"
    @State private var errorMessage: String?
    @State private var showShare = false
    @State private var showMetricGuide = false
    @State private var savedConfirmation = false
    @State private var isDetecting = false
    @State private var detectMessage: String?
    @State private var detectedBall: DetectedBall?
    @State private var shotTask: Task<Void, Never>?

    private var clipDuration: TimeInterval { TimeInterval(clipSeconds) }

    var body: some View {
        NavigationStack {
            ZStack {
                switch phase {
                case .idle: cameraStage { idleStage }
                case .countdown: cameraStage { countdownContent }
                case .recording: cameraStage { recordingContent }
                case .processing: cameraStage { processingContent }
                case .result: resultView.background(Theme.Palette.void)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                camera.requestPermission()
                camera.updatePreviewOrientation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                camera.updatePreviewOrientation()
                // The ball marker is only valid in the orientation it was
                // detected in.
                detectedBall = nil
            }
            .onChange(of: camera.isAuthorized) { _, authorized in
                if authorized { camera.startSession() }
            }
            .onChange(of: selectedClub) { _, club in
                UserDefaults.standard.set(club.rawValue, forKey: "golfmonitor.lastClub")
            }
            .onDisappear {
                camera.stopSession()
                if let activeSessionID = store.activeSessionID {
                    store.endSession(activeSessionID)
                }
            }
            .sheet(isPresented: $showShare, onDismiss: {
                // The sheet can stop the session via onDisappear; restart it.
                camera.requestPermission()
            }) {
                if let img = tracerImage { ShareSheet(items: [img]) }
            }
        }
    }

    // MARK: Full-bleed camera stage

    /// Full-bleed camera with the range HUD layered over the live preview.
    private func cameraStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            if camera.isSessionRunning {
                CameraPreviewView(previewLayer: camera.previewLayer)
                    .ignoresSafeArea(edges: .top)
            } else {
                Theme.Palette.void.ignoresSafeArea(edges: .top)
            }
            content()
        }
    }

    // MARK: Idle — floating record button over the video

    /// Idle stage: ball marker (if a ball was detected) under the controls.
    private var idleStage: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Theme.Palette.void.opacity(0.58), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: Theme.Palette.void.opacity(0.18), location: 0.58),
                    .init(color: Theme.Palette.void.opacity(0.96), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if let ball = detectedBall {
                BallMarkerView(ball: ball)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            idleControls
        }
    }

    private var idleControls: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                ZStack(alignment: .topLeading) {
                    sessionHeader
                        .frame(maxWidth: min(geometry.size.width * 0.55, 440), alignment: .leading)

                    HStack {
                        Spacer(minLength: 0)
                        VStack(spacing: 10) {
                            if !camera.isSessionRunning {
                                cameraConnectionCard
                            }

                            if let err = errorMessage {
                                inlineNotice(err, color: Theme.Palette.signalRed, icon: "exclamationmark.triangle.fill")
                            }

                            if let msg = detectMessage {
                                inlineNotice(
                                    msg,
                                    color: detectedBall == nil ? Theme.Palette.caution : Theme.Palette.ion,
                                    icon: detectedBall == nil ? "scope" : "checkmark.circle.fill"
                                )
                            }

                            shotControlDeck(compact: true)
                        }
                        .frame(width: min(340, geometry.size.width * 0.4))
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    sessionHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    Spacer(minLength: 28)

                    if !camera.isSessionRunning {
                        cameraConnectionCard
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }

                    if let err = errorMessage {
                        inlineNotice(err, color: Theme.Palette.signalRed, icon: "exclamationmark.triangle.fill")
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    if let msg = detectMessage {
                        inlineNotice(
                            msg,
                            color: detectedBall == nil ? Theme.Palette.caution : Theme.Palette.ion,
                            icon: detectedBall == nil ? "scope" : "checkmark.circle.fill"
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }

                    shotControlDeck()
                }
            }
        }
    }

    private var sessionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.Palette.plasma.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: "figure.golf")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.Palette.plasma)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("GOLF MONITOR")
                    .font(Theme.Font.label)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.floodlight)
                Text("RANGE SESSION")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Theme.Palette.mist)
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Circle()
                    .fill(camera.isSessionRunning ? Theme.Palette.ion : Theme.Palette.caution)
                    .frame(width: 7, height: 7)
                    .shadow(color: camera.isSessionRunning ? Theme.Palette.ion.opacity(0.8) : .clear, radius: 5)
                Text(camera.isSessionRunning ? "LIVE" : "CONNECTING")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Palette.floodlight)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassCapsule(clear: true)
        }
        .padding(12)
        .glassCard(cornerRadius: 20, clear: true)
    }

    private var cameraConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.caution)
                VStack(alignment: .leading, spacing: 3) {
                    Text(camera.lastError == nil ? "Warming up the viewfinder" : "Camera unavailable")
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.floodlight)
                    Text(camera.lastError ?? "Your live range view will appear here.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button("Start camera", systemImage: "arrow.clockwise") {
                camera.requestPermission()
            }
            .font(.subheadline.bold())
            .foregroundStyle(Theme.Palette.void)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.Palette.plasma, in: Capsule())
        }
        .padding(16)
        .glassCard(cornerRadius: 20, clear: true)
    }

    private func shotControlDeck(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            challengeCard

            HStack {
                CapsLabel("Shot setup")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: detectedBall == nil ? "scope" : "checkmark.circle.fill")
                    Text(detectedBall == nil ? "BALL NOT LOCKED" : "BALL LOCKED")
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(detectedBall == nil ? Theme.Palette.caution : Theme.Palette.ion)
            }

            clubSelector

            HStack(spacing: 12) {
                durationSelector(title: "COUNTDOWN", selection: $countdownSeconds)
                durationSelector(title: "CLIP", selection: $clipSeconds)
            }

            shotActions
        }
        .padding(compact ? 12 : 16)
        .glassCard(cornerRadius: 26, clear: true)
    }

    @ViewBuilder
    private var challengeCard: some View {
        if !router.rangeContext.isFree, router.rangeContext.isFinished() {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel("Challenge complete", color: Theme.Palette.ion)
                Text(router.rangeContext.subtitle)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.floodlight)
                Button("Finish challenge", systemImage: "checkmark") {
                    router.endPractice()
                    if let activeSessionID = store.activeSessionID {
                        store.endSession(activeSessionID)
                    }
                }
                .font(.subheadline.bold())
                .foregroundStyle(Theme.Palette.void)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.Palette.ion, in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassCard(cornerRadius: 18, clear: true)
        } else if !router.rangeContext.isFree,
                  let target = router.rangeContext.currentTarget() {
            HStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.plasma)
                VStack(alignment: .leading, spacing: 3) {
                    CapsLabel(router.rangeContext.title, color: Theme.Palette.plasma)
                    Text(target.label)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.floodlight)
                }
                Spacer()
                Text(router.rangeContext.subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.mist)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .padding(14)
            .glassCard(cornerRadius: 18, clear: true)
        }
    }

    private var clubSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Club.allCases) { club in
                    let selected = selectedClub == club
                    Button {
                        Haptics.select()
                        selectedClub = club
                    } label: {
                        Text(club.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Theme.Palette.void : Theme.Palette.floodlight)
                            .padding(.horizontal, 15)
                            .frame(height: 38)
                            .background(
                                selected ? Theme.Palette.plasma.opacity(0.82) : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    selected ? Theme.Palette.plasma : Theme.Palette.hairline,
                                    lineWidth: 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .contentMargins(.trailing, 2)
    }

    private var shotActions: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                detectBall()
            } label: {
                VStack(spacing: 5) {
                    if isDetecting {
                        ProgressView()
                            .tint(Theme.Palette.floodlight)
                            .frame(height: 19)
                    } else {
                        Image(systemName: "scope")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 19)
                    }
                    Text(isDetecting ? "SCANNING" : "FIND BALL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                }
                .foregroundStyle(Theme.Palette.floodlight)
                .frame(width: 82, height: 58)
                .glassCard(cornerRadius: 16, interactive: true, clear: true)
            }
            .buttonStyle(.plain)
            .disabled(isDetecting || !camera.isAuthorized || !camera.isSessionRunning)

            Button {
                Haptics.impact(.medium)
                camera.lockFocusAndExposure()
                startShot()
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECORD SHOT")
                            .font(.system(size: 14, weight: .black))
                            .tracking(0.8)
                        Text(recordButtonSubtitle)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.25)
                            .opacity(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Theme.Palette.floodlight)
                .padding(.horizontal, 17)
                .frame(maxWidth: .infinity, minHeight: 58)
                .glassCard(
                    cornerRadius: 16,
                    tint: canRecord ? Theme.Palette.plasma : nil,
                    interactive: canRecord,
                    clear: true
                )
                .shadow(color: canRecord ? Theme.Palette.plasma.opacity(0.22) : .clear, radius: 16, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(!canRecord)
            .animation(Theme.Motion.snappy, value: canRecord)
        }
    }

    private var recordButtonSubtitle: String {
        canRecord ? "\(Int(clipDuration)) SEC · \(Int(camera.selectedFPS)) FPS" : "FIND THE BALL TO UNLOCK"
    }

    private func inlineNotice(_ message: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.floodlight)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 14, clear: true)
    }

    private func durationSelector(title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel(title, color: Theme.Palette.mist)
            HStack(spacing: 3) {
                ForEach([3, 5, 10, 15], id: \.self) { seconds in
                    let selected = selection.wrappedValue == seconds
                    Button {
                        Haptics.select()
                        selection.wrappedValue = seconds
                    } label: {
                        Text("\(seconds)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(selected ? Theme.Palette.void : Theme.Palette.mist)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(
                                selected ? Theme.Palette.ion.opacity(0.82) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassCard(cornerRadius: 11, clear: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Countdown / recording / processing overlays

    private var countdownContent: some View {
        VStack(spacing: 0) {
            sessionHeader
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 12) {
                CapsLabel("Get set", color: Theme.Palette.plasma)
                Text("\(countdownValue)")
                    .font(Theme.Font.mega(150))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.floodlight)
                    .contentTransition(.numericText(value: Double(countdownValue)))
                    .shadow(color: Theme.Palette.plasma.opacity(0.35), radius: 30)
                    .id(countdownValue)
                    .transition(.scale.combined(with: .opacity))
                Text("Swing on zero")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.mist)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 38)
            .contentCard(cornerRadius: 28, elevated: true)
            .padding(.horizontal, 28)
            Spacer()
            cancelShotButton
                .padding(.bottom, 24)
        }
        .animation(Theme.Motion.snappy, value: countdownValue)
    }

    private var recordingContent: some View {
        VStack(spacing: 0) {
            sessionHeader
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 14) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Theme.Palette.signalRed)
                        .frame(width: 9, height: 9)
                        .shadow(color: Theme.Palette.signalRed.opacity(0.85), radius: 8)
                    CapsLabel("Recording live", color: Theme.Palette.signalRed)
                }
                Text("Swing now")
                    .font(Theme.Font.display)
                    .foregroundStyle(Theme.Palette.floodlight)
                Text("Capturing \(Int(clipDuration)) seconds · \(Int(camera.selectedFPS)) FPS")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.mist)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .contentCard(cornerRadius: 26, elevated: true)
            .padding(.horizontal, 24)
            Spacer()
            cancelShotButton
                .padding(.bottom, 24)
        }
    }

    private var cancelShotButton: some View {
        Button("Cancel shot", systemImage: "xmark.circle.fill", action: cancelShot)
            .font(.subheadline.bold())
            .foregroundStyle(Theme.Palette.floodlight)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassCapsule(interactive: true, clear: true)
    }

    private var processingContent: some View {
        VStack(spacing: 0) {
            sessionHeader
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.Palette.plasma)
                CapsLabel("Shot intelligence", color: Theme.Palette.plasma)
                Text(processingStatus)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.floodlight)
                    .multilineTextAlignment(.center)
                Text("Tracking flight · reading swing · building your shot")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.mist)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(26)
            .contentCard(cornerRadius: 24, elevated: true)
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: Result card

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        CapsLabel("Range session", color: Theme.Palette.plasma)
                        Text("Shot review")
                            .font(Theme.Font.display)
                            .foregroundStyle(Theme.Palette.floodlight)
                    }
                    Spacer()
                    Text(selectedClub.rawValue.uppercased())
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.mist)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .glassCapsule(clear: true)
                }

                if let img = tracerImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                showShare = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.floodlight)
                                    .frame(width: 40, height: 40)
                                    .glassCapsule(interactive: true, clear: true)
                            }
                            .padding(8)
                        }
                }

                Text(analysisOutput?.analysis.pipeline ?? "Swing analysis")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Palette.dim)

                if let m = metrics {
                    VStack(alignment: .leading, spacing: 4) {
                        CapsLabel("Ball speed", color: Theme.Palette.mist)
                        Text(formatSpeed(mph: m.ballSpeedMph, settings: settings))
                            .font(Theme.Font.hero(76))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Palette.floodlight)
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                        Text("MEASURED FROM YOUR SWING")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Palette.ion)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .contentCard(cornerRadius: 22, elevated: true)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metricTile("Carry · estimated", formatDistance(yards: m.carryYards, settings: settings))
                        metricTile("Club Speed", formatSpeed(mph: m.clubSpeedMph, settings: settings))
                        metricTile("Smash Factor", m.smashFactor > 0 ? String(format: "%.2f", m.smashFactor) : "—")
                        metricTile("Launch Angle", String(format: "%.1f°", m.launchAngleDeg))
                        metricTile("Offline · estimate", formatOffline(yards: m.offlineYards, settings: settings))
                        metricTile("Apex · estimated", formatDistance(yards: m.apexYards, settings: settings))
                        metricTile("Hang Time", String(format: "~%.1fs", m.hangTimeS))
                        metricTile("Tempo", formatTempo(m.tempoRatio))
                    }

                    Text("Spin isn’t measured by a phone camera. Carry, apex and offline are estimates.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.mist)
                        .padding(.horizontal, 2)

                    Button {
                        showMetricGuide = true
                    } label: {
                        Label("What these numbers mean", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Palette.plasma)
                    }
                    .sheet(isPresented: $showMetricGuide) {
                        MetricGuideView()
                    }

                    // Club selector
                    VStack(alignment: .leading, spacing: 8) {
                        CapsLabel("Club", color: Theme.Palette.mist)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Club.allCases) { club in
                                    Button {
                                        selectedClub = club
                                    } label: {
                                        Text(club.rawValue)
                                            .font(.subheadline.bold())
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(selectedClub == club ? Theme.Palette.plasma : Theme.Palette.graphite,
                                                        in: Capsule())
                                            .foregroundStyle(selectedClub == club ? Theme.Palette.void : Theme.Palette.floodlight)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                }

                if let err = errorMessage {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.caution)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentCard(cornerRadius: 16)
                }

                if let feedback = practiceFeedback {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feedback.headline)
                            .font(.headline)
                            .foregroundStyle(Theme.Palette.floodlight)
                        if !feedback.detail.isEmpty {
                            Text(feedback.detail)
                                .font(.subheadline)
                                .foregroundStyle(Theme.Palette.mist)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .contentCard(cornerRadius: 16)
                }

                if analysisOutput != nil {
                    Button {
                        saveShot()
                    } label: {
                        Text(savedConfirmation ? "Saved ✓" : "Save Shot")
                            .font(.system(size: 14, weight: .black))
                            .tracking(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Theme.Palette.plasma, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(Theme.Palette.void)
                    }
                    .disabled(savedConfirmation)
                }

                if savedConfirmation, let savedShotID {
                    Button {
                        router.openStudio(savedShotID)
                    } label: {
                        Label("Open in Swing Studio", systemImage: "play.rectangle")
                            .font(.headline)
                            .foregroundStyle(Theme.Palette.ion)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .contentCard(cornerRadius: 16)
                    }
                }

                Button(action: reset) {
                    Label("Record another shot", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.Palette.mist)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.void)
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(Theme.Font.label)
                .tracking(0.5)
                .foregroundStyle(Theme.Palette.mist)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(Theme.Font.metric(27))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.floodlight)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(14)
        .contentCard(cornerRadius: 16)
    }

    // MARK: Flow

    /// Recording unlocks only after a current, in-range ball detection.
    private var canRecord: Bool {
        phase == .idle && camera.isAuthorized && camera.isSessionRunning
            && detectedBall != nil && !router.rangeContext.isFinished()
    }

    /// One-tap calibration from the Session screen: grab a frame, find the
    /// ball, derive the px/m scale from its known diameter, save immediately.
    private func detectBall() {
        guard camera.isSessionRunning else { return }
        isDetecting = true
        detectMessage = nil
        detectedBall = nil
        camera.captureSingleFrame { buffer in
            let outcome = TrackingEngine.detectBall(in: buffer)
            DispatchQueue.main.async {
                self.isDetecting = false
                guard let ball = outcome.ball else {
                    self.detectMessage = "Core ML detection failed: \(outcome.failureReason ?? "No ball detected.")"
                    return
                }
                let candidates = outcome.candidates.isEmpty ? [ball] : outcome.candidates
                let centeredCandidates = DetectedBall.centeredCandidates(in: candidates)
                guard !centeredCandidates.isEmpty else {
                    self.detectMessage = "No ball detected near the center of the frame. Center the ball and try again."
                    return
                }
                let measured = centeredCandidates.compactMap { candidate -> (ball: DetectedBall, distance: Double)? in
                    guard let distance = self.ballDistanceMeters(candidate) else { return nil }
                    return (candidate, distance)
                }
                let inRange = measured
                    .filter { Self.acceptedBallDistanceMeters.contains($0.distance) }
                guard let selected = inRange.first else {
                    guard let closest = measured.min(by: {
                        self.distanceOutsideAcceptedRange($0.distance)
                            < self.distanceOutsideAcceptedRange($1.distance)
                    }) else {
                        self.detectMessage = "Could not estimate ball distance — check camera framing and try again."
                        return
                    }
                    self.detectMessage = String(
                        format: "Ball appears ~%.1f m away — detection allowed only from 0.5–2.0 m.",
                        closest.distance
                    )
                    return
                }
                let selectedBall = selected.ball
                let distance = selected.distance
                self.detectedBall = selectedBall
                var cal = Calibration.load()
                cal.ballDiameterPx = selectedBall.diameter
                cal.pixelsPerMeter = selectedBall.diameter / Calibration.golfBallDiameterMeters
                cal.isCalibrated = true
                cal.save()
                self.detectMessage = String(
                    format: "Ball detected — ~%.1f m (%.1f ft) from camera ✓",
                    distance, distance * 3.28084
                )
            }
        }
    }

    /// Distance estimate from the ball's apparent size. With the format's
    /// field of view, the focal length in pixels is
    /// f = (longSide/2) / tan(FOV/2), and distance = f × realDiameter /
    /// pixelDiameter. The frame's long side is used so the estimate is the
    /// same in portrait and landscape.
    private func ballDistanceMeters(_ ball: DetectedBall) -> Double? {
        let fov = camera.fieldOfViewDegrees
        guard fov.isFinite, fov > 1, ball.diameter.isFinite, ball.diameter > 0 else { return nil }
        let longSide = Double(max(ball.frameWidth, ball.frameHeight))
        let focalPx = (longSide / 2) / tan(fov * .pi / 360)
        let distance = focalPx * Calibration.golfBallDiameterMeters / ball.diameter
        return distance.isFinite ? distance : nil
    }

    private func distanceOutsideAcceptedRange(_ distance: Double) -> Double {
        if distance < Self.acceptedBallDistanceMeters.lowerBound {
            return Self.acceptedBallDistanceMeters.lowerBound - distance
        }
        if distance > Self.acceptedBallDistanceMeters.upperBound {
            return distance - Self.acceptedBallDistanceMeters.upperBound
        }
        return 0
    }

    private func startShot() {
        errorMessage = nil
        detectMessage = nil
        savedConfirmation = false
        metrics = nil
        analysisOutput = nil
        analysisRequest = nil
        capturedClipURL = nil
        savedShotID = nil
        practiceFeedback = nil
        tracerImage = nil
        phase = .countdown
        if store.activeSessionID == nil {
            _ = store.startSession(cameraView: settings.cameraView,
                                   gameID: router.rangeContext.gameID,
                                   title: router.rangeContext.title)
        }
        shotTask = Task { @MainActor in
            for i in stride(from: countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                countdownValue = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            phase = .recording
            let fps = camera.selectedFPS > 0 ? camera.selectedFPS : 240
            camera.startRecording(duration: clipDuration) { url in
                // Completion is delivered on the main queue.
                guard self.phase == .recording else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.handleClip(url, fps: fps)
            }
        }
    }

    private func cancelShot() {
        shotTask?.cancel()
        shotTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        camera.cancelRecording()
        camera.unlockFocusAndExposure()
        phase = .idle
        if let capturedClipURL {
            try? FileManager.default.removeItem(at: capturedClipURL)
        }
        capturedClipURL = nil
        analysisOutput = nil
        analysisRequest = nil
        practiceFeedback = nil
        metrics = nil
        tracerImage = nil
        errorMessage = nil
    }

    private func handleClip(_ url: URL?, fps: Double) {
        guard let url else {
            phase = .idle
            errorMessage = "Recording failed. Try again."
            return
        }
        phase = .processing
        processingStatus = "Analyzing frames…"
        let calibration = Calibration.load()
        let request = AnalysisRequest(
            clipURL: url,
            club: selectedClub,
            cameraView: settings.cameraView,
            handedness: settings.handedness,
            calibration: calibration.isCalibrated ? calibration : nil,
            captureFPS: fps
        )
        analysisRequest = request
        capturedClipURL = url
        phase = .processing
        processingStatus = "Tracking ball and reading pose…"

        analysisTask = Task {
            do {
                let output = try await SwingAnalyzer().analyze(request) { _, status in
                    DispatchQueue.main.async { self.processingStatus = status }
                }
                guard !Task.isCancelled else { return }
                self.analysisOutput = output
                self.metrics = output.metrics
                self.tracerImage = output.tracerImage
                self.errorMessage = output.metricsError
                self.phase = .result
                self.analysisTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "Swing analysis failed: \(error.localizedDescription)"
                self.phase = .result
                self.analysisTask = nil
            }
        }
    }

    private func saveShot() {
        guard let output = analysisOutput,
              var request = analysisRequest,
              let clipURL = capturedClipURL else { return }
        request.club = selectedClub
        var shot = Shot.make(from: output, request: request)
        if let target = router.rangeContext.currentTarget() {
            shot.practice = PracticeContext(
                gameID: router.rangeContext.gameID ?? "practice",
                targetCarryYards: target.carryYards
            )
        }
        let saved = store.addShot(shot, clipURL: clipURL,
                                  analysis: output.analysis,
                                  thumbnail: output.thumbnail)
        savedShotID = saved.id
        if let feedback = router.rangeContext.onShot(saved) {
            practiceFeedback = feedback
            if var savedShot = store.shot(id: saved.id) {
                savedShot.practice?.points = feedback.points
                store.update(savedShot)
            }
        }
        savedConfirmation = true
    }

    private func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        phase = .idle
        analysisOutput = nil
        analysisRequest = nil
        if let capturedClipURL,
           FileManager.default.fileExists(atPath: capturedClipURL.path) {
            try? FileManager.default.removeItem(at: capturedClipURL)
        }
        capturedClipURL = nil
        savedShotID = nil
        metrics = nil
        tracerImage = nil
        errorMessage = nil
        detectMessage = nil
        detectedBall = nil
        savedConfirmation = false
        camera.unlockFocusAndExposure()
        // Restart the session if a sheet presentation or tab switch stopped it.
        camera.requestPermission()
    }
}
