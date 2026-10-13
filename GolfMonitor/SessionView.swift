import SwiftUI
import AVFoundation
import UIKit
import Combine

// MARK: - Camera preview wrapper (shared by Session & Setup tabs)

/// UIView that keeps the preview layer sized to its bounds on every layout
/// pass (including rotation), so the viewfinder always fills its frame.
final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let layer = previewLayer {
                layer.videoGravity = .resizeAspectFill
                self.layer.addSublayer(layer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    var previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = previewLayer
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Session view

struct SessionView: View {
    @StateObject private var camera = CameraManager()
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore

    private enum Phase { case idle, countdown, recording, processing, result }

    @State private var phase: Phase = .idle
    @State private var countdownValue = 3
    @State private var selectedClub: Club = .driver
    @State private var metrics: ShotMetrics?
    @State private var tracerImage: UIImage?
    @State private var processingStatus = "Analyzing frames…"
    @State private var errorMessage: String?
    @State private var showShare = false
    @State private var savedConfirmation = false

    private let clipDuration = 2.0

    var body: some View {
        NavigationStack {
            ZStack {
                switch phase {
                case .idle: cameraStage { idleControls }
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
            }
            .onChange(of: camera.isAuthorized) { _, authorized in
                if authorized { camera.startSession() }
            }
            .onDisappear { camera.stopSession() }
            .sheet(isPresented: $showShare) {
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

    private var idleControls: some View {
        VStack(spacing: 0) {
            HStack {
                Text(camera.selectedFPS > 0 ? String(format: "%.0f fps · %@", camera.selectedFPS, camera.selectedResolution) : "starting camera…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .opacity(camera.isSessionRunning ? 1 : 0)

            if !camera.isSessionRunning {
                Spacer()
                Text(camera.lastError ?? "Starting camera…")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
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

            Spacer()

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
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .background(camera.isAuthorized && camera.isSessionRunning ? Color.accentColor : Color.gray,
                            in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            .disabled(!camera.isAuthorized || !camera.isSessionRunning)
            .padding(.bottom, 18)
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
        }
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
            Text("Tracking the ball frame by frame")
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
                        metricTile("Club Speed", formatSpeed(mph: m.clubSpeedMph, settings: settings))
                        metricTile("Smash Factor", m.smashFactor > 0 ? String(format: "%.2f", m.smashFactor) : "—")
                        metricTile("Launch Angle", String(format: "%.1f°", m.launchAngleDeg))
                        metricTile("Carry ~", formatDistance(yards: m.carryYards, settings: settings))
                        metricTile("Apex ~", formatDistance(yards: m.apexYards, settings: settings))
                        metricTile("Hang Time", String(format: "~%.1fs", m.hangTimeS))
                        metricTile("Tempo", formatTempo(m.tempoRatio))
                        metricTile("Offline ~", formatOffline(yards: m.offlineYards, settings: settings))
                    }
                    .padding(.horizontal)

                    Text("Spin: n/a — phone cameras can't measure spin")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                    Button {
                        saveShot(metrics: m)
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
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(err)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 60)
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
        let cal = Calibration.load()
        return Label(cal.isCalibrated ? "Calibrated" : "Not calibrated",
                     systemImage: cal.isCalibrated ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(cal.isCalibrated ? .green : .orange)
    }

    // MARK: Flow

    private func startShot() {
        errorMessage = nil
        savedConfirmation = false
        metrics = nil
        tracerImage = nil
        phase = .countdown
        Task {
            for i in [3, 2, 1] {
                await MainActor.run { countdownValue = i }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await MainActor.run { phase = .recording }
            let fps = await MainActor.run { camera.selectedFPS > 0 ? camera.selectedFPS : 240 }
            camera.startRecording(duration: clipDuration) { url in
                // Completion is delivered on the main queue.
                self.handleClip(url, fps: fps)
            }
        }
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
        let ppm = calibration.pixelsPerMeter
        let expectedDiameter = calibration.ballDiameterPx
        let club = selectedClub

        DispatchQueue.global(qos: .userInitiated).async {
            let engine = TrackingEngine()
            let tracking = engine.track(videoURL: url, fps: fps,
                                        expectedBallDiameterPx: expectedDiameter)
            var computed: ShotMetrics?
            var failure: String?
            do {
                computed = try MetricsCalculator.calculate(tracking: tracking,
                                                           pixelsPerMeter: ppm,
                                                           club: club)
            } catch {
                failure = error.localizedDescription
            }
            let tracer = TracerRenderer.makeTracerImage(videoURL: url, tracking: tracking)
            DispatchQueue.main.async {
                self.metrics = computed
                self.tracerImage = tracer
                self.errorMessage = failure
                self.phase = .result
            }
        }
    }

    private func saveShot(metrics m: ShotMetrics) {
        let shot = Shot(
            club: selectedClub,
            ballSpeedMph: m.ballSpeedMph,
            clubSpeedMph: m.clubSpeedMph,
            launchAngleDeg: m.launchAngleDeg,
            carryYards: m.carryYards,
            apexYards: m.apexYards,
            hangTimeS: m.hangTimeS,
            smashFactor: m.smashFactor,
            tempoRatio: m.tempoRatio,
            offlineYards: m.offlineYards,
            notes: ""
        )
        store.addShot(shot)
        savedConfirmation = true
    }

    private func reset() {
        phase = .idle
        metrics = nil
        tracerImage = nil
        errorMessage = nil
        savedConfirmation = false
        camera.unlockFocusAndExposure()
    }
}

// MARK: - Shot tracer renderer

/// Extracts a frame from the clip and draws the tracked ball trajectory over it.
enum TracerRenderer {

    static func makeTracerImage(videoURL: URL, tracking: TrackingResult) -> UIImage? {
        guard !tracking.ballPoints.isEmpty else { return nil }
        // Show a frame a bit after impact so the ball trail is visible.
        let impactTime = tracking.impactBallIndex
            .flatMap { tracking.ballPoints.indices.contains($0) ? tracking.ballPoints[$0].time : nil } ?? 0
        let frameTime = min(impactTime + 0.12, tracking.ballPoints.last?.time ?? 0.5)
        guard let base = frameImage(videoURL: videoURL, at: frameTime),
              let cg = base.cgImage
        else { return nil }

        let imgW = CGFloat(cg.width), imgH = CGFloat(cg.height)
        let sx = imgW / CGFloat(max(tracking.frameWidth, 1))
        let sy = imgH / CGFloat(max(tracking.frameHeight, 1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imgW, height: imgH), format: format)
        return renderer.image { _ in
            base.draw(in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
            guard let ctx = UIGraphicsGetCurrentContext() else { return }

            // Ball trail (yellow).
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(max(3, imgW / 320))
            ctx.setLineCap(.round)
            ctx.beginPath()
            for (i, p) in tracking.ballPoints.enumerated() {
                let q = CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy)
                if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
            }
            ctx.strokePath()

            // Impact marker (red dot).
            if let idx = tracking.impactBallIndex,
               tracking.ballPoints.indices.contains(idx) {
                let p = tracking.ballPoints[idx]
                let q = CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy)
                ctx.setFillColor(UIColor.systemRed.cgColor)
                let r = max(6, imgW / 160)
                ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2))
            }

            // Club trail pre-impact (cyan, thin).
            if tracking.clubPoints.count >= 2 {
                ctx.setStrokeColor(UIColor.systemCyan.cgColor)
                ctx.setLineWidth(max(2, imgW / 480))
                ctx.beginPath()
                for (i, p) in tracking.clubPoints.enumerated() {
                    let q = CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy)
                    if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
                }
                ctx.strokePath()
            }
        }
    }

    private static func frameImage(videoURL: URL, at seconds: Double) -> UIImage? {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}
