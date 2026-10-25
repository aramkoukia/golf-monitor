import SwiftUI
import AVFoundation
import UIKit
import Combine

// Legacy v1 Session tab — replaced by Features/Range. Delete once RangeView ships.

// MARK: - Session view

struct SessionView: View {
    @StateObject private var camera = CameraManager()
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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
    private var isCompactLayout: Bool { verticalSizeClass == .compact }
    private var ballDetectorStatus: String {
        if BundledModel.golfDetector.isAvailable { return "Ball detection: GolfDetector · Core ML" }
        if BundledModel.cocoDetector.isAvailable { return "Ball detection: COCO sports-ball · Core ML" }
        return "Ball detection model unavailable"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch phase {
                case .idle: cameraStage { idleStage }
                case .countdown: cameraStage { countdownContent }
                case .recording: cameraStage { recordingContent }
                case .processing: cameraStage { processingContent }
                case .result: resultView.background(Color(.systemBackground))
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    calibrationBadge
                }
            }
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

    /// Full-bleed camera with overlay content on top. The nav bar and tab bar
    /// stay visible; the video extends under the nav bar.
    private func cameraStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            if camera.isSessionRunning {
                CameraPreviewView(previewLayer: camera.previewLayer)
                    .ignoresSafeArea(edges: .top)
            } else {
                Color(.systemBackground).ignoresSafeArea(edges: .top)
            }
            content()
        }
    }

    // MARK: Idle — floating record button over the video

    /// Idle stage: ball marker (if a ball was detected) under the controls.
    private var idleStage: some View {
        ZStack {
            if let ball = detectedBall {
                BallMarkerView(ball: ball)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            idleControls
        }
    }

    private var idleControls: some View {
        VStack(spacing: 0) {
            if !isCompactLayout {
                Text(ballDetectorStatus)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
                    .padding(.bottom, 8)
            }

            if !router.rangeContext.isFree, router.rangeContext.isFinished() {
                VStack(spacing: 6) {
                    Text("CHALLENGE COMPLETE")
                        .font(.caption.bold())
                    Text(router.rangeContext.subtitle)
                        .font(.caption)
                    Button("Finish challenge") {
                        router.endPractice()
                        if let activeSessionID = store.activeSessionID {
                            store.endSession(activeSessionID)
                        }
                    }
                    .font(.subheadline.bold())
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 10)
            } else if !router.rangeContext.isFree,
                      let target = router.rangeContext.currentTarget() {
                VStack(spacing: 3) {
                    Text(router.rangeContext.title.uppercased())
                        .font(.caption2.bold())
                    Text(target.label)
                        .font(.headline.monospacedDigit())
                    Text(router.rangeContext.subtitle)
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 10)
            }

            // Club picker — pick before the shot; the result card keeps a
            // synced copy for last-second corrections before saving.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Club.allCases) { club in
                        Button {
                            selectedClub = club
                        } label: {
                            Text(club.rawValue)
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(selectedClub == club ? Color.accentColor : Color.black.opacity(0.35),
                                            in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, isCompactLayout ? 2 : 8)

            if !camera.isSessionRunning {
                Spacer(minLength: isCompactLayout ? 4 : 0)
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(camera.lastError ?? "Starting camera…")
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Start Camera") {
                        camera.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            Spacer(minLength: isCompactLayout ? 4 : 0)

            if let msg = detectMessage {
                Text(msg)
                    .font(.caption)
                    .lineLimit(isCompactLayout ? 1 : 2)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, isCompactLayout ? 3 : 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, isCompactLayout ? 2 : 10)
            }

            if !isCompactLayout {
                VStack(spacing: 2) {
                    Text(ballDetectorStatus)
                    Text("Clip analysis: GolfDetector (if available) + blob tracking + body pose")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 4)
                .padding(.bottom, 8)
            }

            if detectedBall == nil && !isCompactLayout {
                Text("Detect an in-range ball (0.5–2 m) to enable recording")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 10)
            }

            durationChips(label: "Countdown", selection: $countdownSeconds, compact: isCompactLayout)
                .padding(.bottom, isCompactLayout ? 2 : 8)
            durationChips(label: "Clip", selection: $clipSeconds, compact: isCompactLayout)
                .padding(.bottom, isCompactLayout ? 4 : 12)

            // Keep the primary actions in one row so both remain visible in landscape.
            HStack(spacing: 12) {
                Button {
                    detectBall()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "scope")
                        Text(isDetecting ? "Detecting…" : "Detect ball")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, isCompactLayout ? 8 : 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                }
                .disabled(isDetecting || !camera.isAuthorized || !camera.isSessionRunning)

                Button {
                    camera.lockFocusAndExposure()
                    startShot()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle.fill")
                        Text("Record Shot")
                            .font(.title3.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, isCompactLayout ? 18 : 26)
                    .padding(.vertical, isCompactLayout ? 8 : 13)
                    .background(canRecord ? Color.accentColor : Color.gray,
                                in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .disabled(!canRecord)
            }
            .padding(.bottom, isCompactLayout ? 6 : 18)
        }
    }

    /// iPhone-camera-style duration picker: a row of tappable pills
    /// (3/5/10/15 s) in a dark capsule — no dropdowns.
    private func durationChips(label: String, selection: Binding<Int>, compact: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: compact ? 72 : 80, alignment: .trailing)
            HStack(spacing: 4) {
                ForEach([3, 5, 10, 15], id: \.self) { sec in
                    Button {
                        selection.wrappedValue = sec
                    } label: {
                        Text("\(sec)")
                            .font(.caption.bold())
                            .frame(width: 30, height: compact ? 28 : 32)
                            .background(selection.wrappedValue == sec ? Color.white : Color.white.opacity(0.15), in: Circle())
                            .foregroundStyle(selection.wrappedValue == sec ? .black : .white)
                    }
                }
            }
            .padding(4)
            .background(.black.opacity(0.35), in: Capsule())
            Text("sec")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .shadow(radius: 4)
        }
    }

    // MARK: Countdown / recording / processing overlays

    private var countdownContent: some View {
        VStack {
            Spacer()
            Text("\(countdownValue)")
                .font(.system(size: 120, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(radius: 12)
            Text("Get ready — swing on zero")
                .foregroundStyle(.white)
                .shadow(radius: 6)
            Spacer()
            cancelShotButton
                .padding(.bottom, 24)
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                Text("Recording… swing now!")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            .shadow(radius: 6)
            Text("Capturing \(Int(clipDuration))s at high frame rate")
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 6)
            Spacer()
            cancelShotButton
                .padding(.bottom, 24)
        }
    }

    private var cancelShotButton: some View {
        Button("Cancel shot", systemImage: "xmark.circle.fill", action: cancelShot)
            .font(.subheadline.bold())
            .buttonStyle(.bordered)
            .tint(.white)
    }

    private var processingContent: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text(processingStatus)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .shadow(radius: 6)
            Text("Analyzing ball track and pose…")
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 6)
            Spacer()
        }
    }

    // MARK: Result card

    private var resultView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let img = tracerImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                showShare = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(8)
                        }
                }

                Text(analysisOutput?.analysis.pipeline ?? "Swing analysis")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let m = metrics {
                    // Hero: ball speed
                    VStack(spacing: 2) {
                        Text("BALL SPEED")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(formatSpeed(mph: m.ballSpeedMph, settings: settings))
                            .font(.system(size: 52, weight: .heavy))
                            .monospacedDigit()
                    }
                    .padding(.top, 4)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metricTile("Carry ~", formatDistance(yards: m.carryYards, settings: settings))
                        metricTile("Club Speed", formatSpeed(mph: m.clubSpeedMph, settings: settings))
                        metricTile("Smash Factor", m.smashFactor > 0 ? String(format: "%.2f", m.smashFactor) : "—")
                        metricTile("Launch Angle", String(format: "%.1f°", m.launchAngleDeg))
                        metricTile("Offline ~", formatOffline(yards: m.offlineYards, settings: settings))
                        metricTile("Apex ~", formatDistance(yards: m.apexYards, settings: settings))
                        metricTile("Hang Time", String(format: "~%.1fs", m.hangTimeS))
                        metricTile("Tempo", formatTempo(m.tempoRatio))
                    }
                    .padding(.horizontal)

                    Text("Spin: n/a — phone cameras can't measure spin")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        showMetricGuide = true
                    } label: {
                        Label("What these numbers mean", systemImage: "info.circle")
                            .font(.subheadline)
                    }
                    .sheet(isPresented: $showMetricGuide) {
                        MetricGuideView()
                    }

                    // Club selector
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Club").font(.headline)
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
                                            .background(selectedClub == club ? Color.accentColor : Color.secondary.opacity(0.15),
                                                        in: Capsule())
                                            .foregroundStyle(selectedClub == club ? .white : .primary)
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
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let feedback = practiceFeedback {
                    VStack(spacing: 4) {
                        Text(feedback.headline).font(.headline)
                        if !feedback.detail.isEmpty {
                            Text(feedback.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

                if analysisOutput != nil {
                    Button {
                        saveShot()
                    } label: {
                        Text(savedConfirmation ? "Saved ✓" : "Save Shot")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                    .disabled(savedConfirmation)
                    .padding(.horizontal)
                }

                if savedConfirmation, let savedShotID {
                    Button {
                        router.openStudio(savedShotID)
                    } label: {
                        Label("Open in Swing Studio", systemImage: "play.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .padding(.horizontal)
                }

                Button("Record another") { reset() }
                    .padding(.bottom, 24)
            }
        }
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var calibrationBadge: some View {
        Label(detectedBall == nil ? "Detect ball" : "Ball ready",
              systemImage: detectedBall == nil ? "scope" : "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(detectedBall == nil ? .orange : .green)
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
                let measured = candidates.compactMap { candidate -> (ball: DetectedBall, distance: Double)? in
                    guard let distance = self.ballDistanceMeters(candidate) else { return nil }
                    return (candidate, distance)
                }
                // Equal-sized balls closer to the camera produce larger boxes.
                let inRange = measured
                    .filter { Self.acceptedBallDistanceMeters.contains($0.distance) }
                    .max { $0.ball.diameter < $1.ball.diameter }
                guard let selected = inRange else {
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
