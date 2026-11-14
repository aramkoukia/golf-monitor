import SwiftUI
import WatchKit

/// "Gold Standard" colours for the watch (mirrors the phone's Theme).
enum WatchPalette {
    static let void    = Color(red: 0.039, green: 0.039, blue: 0.043)   // #0A0A0B
    static let carbon  = Color(red: 0.067, green: 0.067, blue: 0.075)   // #111113
    static let floodlight = Color(red: 0.949, green: 0.941, blue: 0.929) // #F2F0ED
    static let mist    = Color(red: 0.604, green: 0.588, blue: 0.565)   // #9A9690
    // Brand gold — matches icon's orbital ring
    static let plasma  = Color(red: 0.788, green: 0.573, blue: 0.165)   // #C9922A
    static let tracer  = Color(red: 0.961, green: 0.851, blue: 0.545)   // #F5D98B
    // Functional / status (unchanged)
    static let ion     = Color(red: 0.24,  green: 0.96,  blue: 0.65)
    static let caution = Color(red: 1,     green: 0.77,  blue: 0.24)
    static let red     = Color(red: 1,     green: 0.23,  blue: 0.19)
    // Background warmth — dark amber ember instead of green turf
    static let turf    = Color(red: 0.078, green: 0.059, blue: 0.027)   // #14100A

    static func tint(_ tone: RemoteScreenModel.Tone) -> Color {
        switch tone {
        case .plasma: return plasma
        case .live: return red
        case .calm: return mist
        case .success: return ion
        case .warning: return caution
        }
    }
}

struct WatchRemoteView: View {
    @EnvironmentObject private var model: WatchSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showClubs = false

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let state = model.state, model.screen.isConnected {
                            Button { showClubs = true } label: {
                                Text(state.clubShort)
                                    .font(.system(size: 15, weight: .black).width(.compressed))
                                    .foregroundStyle(WatchPalette.floodlight)
                            }
                            .disabled(state.phase == .recording || state.phase == .processing)
                            .accessibilityLabel("Club \(state.club)")
                        }
                    }
                }
                .sheet(isPresented: $showClubs) {
                    ClubPickerSheet(current: model.state?.club) { model.selectClub($0) }
                }
        }
        .onAppear { model.activate() }
        .onChange(of: scenePhase) { _, phase in
            model.setPreviewVisible(phase == .active && model.screen.wantsPreview)
            if phase == .active { model.send(.requestState) }
        }
        .onChange(of: model.screen.wantsPreview) { _, wants in
            model.setPreviewVisible(wants && scenePhase == .active)
        }
        .task { model.setPreviewVisible(model.screen.wantsPreview) }
        #if DEBUG
        .task { await debugAutostart() }
        #endif
    }

    #if DEBUG
    /// `-gm.autostart [seconds]`: once the phone is ready, press Start, then
    /// Stop after `seconds` (default 6) — for end-to-end checks in the Simulator.
    private func debugAutostart() async {
        let args = ProcessInfo.processInfo.arguments
        if let m = args.firstIndex(of: "-gm.mockState"), m + 1 < args.count, let phase = RemotePhase(rawValue: args[m + 1]) {
            model.applyMockState(phase)
            return
        }
        guard let i = args.firstIndex(of: "-gm.autostart") else { return }
        let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 6
        var waited = 0
        while model.screen.primary != .start, waited < 240 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        model.performPrimaryAction()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if model.screen.primary == .stop { model.performPrimaryAction() }
    }
    #endif

    @ViewBuilder
    private var content: some View {
        let screen = model.screen
        switch (screen.isConnected, model.state?.phase) {
        case (false, _), (true, .notReady), (true, nil):
            ConnectionView(screen: screen) { model.send(.requestState) }
        case (true, .ready), (true, .recording):
            CaptureView()
        case (true, .processing):
            AnalyzingView(progress: model.state?.progress ?? 0, detail: screen.detail)
        case (true, .result):
            ResultView(summary: model.state?.lastShot) { model.performPrimaryAction() }
        case (true, .error):
            ErrorView(message: screen.detail) { model.performPrimaryAction() }
        }
    }
}

// MARK: - Capture (ready + recording)

private struct CaptureView: View {
    @EnvironmentObject private var model: WatchSessionModel

    var body: some View {
        let screen = model.screen
        let recording = model.state?.phase == .recording
        ZStack {
            PreviewBackdrop(image: model.hasLivePreview ? model.preview : nil, recording: recording)
            VStack(spacing: 6) {
                StatusPill(recording: recording, startedAt: model.recordingStartedAt,
                           ballLocked: model.state?.ballLocked ?? false,
                           readiness: model.state?.readiness,
                           fps: model.state?.fps ?? 0)
                Spacer(minLength: 0)
                BigButton(recording: recording, pending: model.pendingCommand != nil,
                          startedAt: model.recordingStartedAt,
                          limit: model.state?.maxRecordingSeconds ?? 300) {
                    model.performPrimaryAction()
                }
                Text(model.lastError ?? screen.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.lastError == nil ? WatchPalette.floodlight : WatchPalette.caution)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .shadow(color: .black, radius: 3)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 6)
        }
        .animation(.snappy, value: recording)
        .animation(.snappy, value: screen.detail)
    }
}

private struct PreviewBackdrop: View {
    var image: UIImage?
    var recording: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [WatchPalette.turf, WatchPalette.void], startPoint: .bottom, endPoint: .top)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(WatchPalette.mist.opacity(0.35))
                        .symbolEffect(.pulse, options: .repeating)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .clear, location: 0.3),
                                       .init(color: .black.opacity(0.75), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                if recording {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(WatchPalette.red.opacity(0.9), lineWidth: 3)
                        .blur(radius: 1.5)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: image != nil)
        .accessibilityHidden(true)
    }
}

private struct StatusPill: View {
    var recording: Bool
    var startedAt: Date?
    var ballLocked: Bool
    /// nil from phones that predate the readiness check.
    var readiness: RemoteReadiness?
    var fps: Int

    var body: some View {
        HStack(spacing: 5) {
            if recording, let startedAt {
                Circle().fill(WatchPalette.red).frame(width: 7, height: 7)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(RemoteFormat.clock(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 15, weight: .heavy).width(.compressed))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if ballLocked {
                    Image(systemName: "scope")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WatchPalette.ion)
                        .accessibilityLabel("Ball locked")
                }
            } else if let readiness {
                Image(systemName: icon(for: readiness))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color(for: readiness))
                Text(readiness.label)
                    .font(.system(size: 11, weight: .heavy).width(.condensed))
                    .foregroundStyle(readiness.isReady ? WatchPalette.ion : WatchPalette.floodlight)
            } else {
                Image(systemName: ballLocked ? "scope" : "viewfinder")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ballLocked ? WatchPalette.ion : WatchPalette.floodlight)
                Text(ballLocked ? "BALL LOCKED" : (fps > 0 ? "LIVE · \(fps) FPS" : "LIVE"))
                    .font(.system(size: 11, weight: .heavy).width(.condensed))
            }
        }
        .foregroundStyle(WatchPalette.floodlight)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func icon(for readiness: RemoteReadiness) -> String {
        switch readiness {
        case .ready, .readySwingOnly: return "checkmark.circle.fill"
        case .noBall: return "viewfinder"
        case .ballAtEdge: return "arrow.left.and.right"
        case .tooDark: return "sun.min"
        case .phoneMoved: return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private func color(for readiness: RemoteReadiness) -> Color {
        switch readiness {
        case .ready, .readySwingOnly: return WatchPalette.ion
        case .noBall: return WatchPalette.floodlight
        case .ballAtEdge, .tooDark, .phoneMoved: return WatchPalette.caution
        }
    }
}

private struct BigButton: View {
    var recording: Bool
    var pending: Bool
    var startedAt: Date?
    var limit: TimeInterval
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 3)
                if recording, let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Circle()
                            .trim(from: 0, to: min(1, context.date.timeIntervalSince(startedAt) / max(limit, 1)))
                            .stroke(WatchPalette.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                RoundedRectangle(cornerRadius: recording ? 7 : 30, style: .continuous)
                    .fill(recording ? WatchPalette.red : WatchPalette.plasma)
                    .frame(width: recording ? 28 : 58, height: recording ? 28 : 58)
                    .shadow(color: (recording ? WatchPalette.red : WatchPalette.plasma).opacity(0.8), radius: 8)
                if pending {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 70, height: 70)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .animation(.bouncy, value: recording)
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }
}

// MARK: - Other phases

private struct ConnectionView: View {
    var screen: RemoteScreenModel
    var retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: screen.isConnected ? "camera.badge.ellipsis" : "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(WatchPalette.tint(screen.tone))
                    .symbolEffect(.pulse, options: .repeating)
                    .padding(.top, 6)
                Text(screen.title)
                    .font(.system(size: 17, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(screen.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(WatchPalette.mist)
                    .multilineTextAlignment(.center)
                Button("Check again", action: retry)
                    .tint(WatchPalette.plasma)
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(WatchPalette.turf.gradient, for: .navigation)
    }
}

private struct AnalyzingView: View {
    var progress: Double
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(AngularGradient(colors: [WatchPalette.plasma.opacity(0.2), WatchPalette.plasma, WatchPalette.tracer],
                                            center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: progress)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 26, weight: .heavy).width(.compressed))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress))
            }
            .frame(width: 96, height: 96)
            Text("Analyzing on iPhone")
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(WatchPalette.mist)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .containerBackground(WatchPalette.void.gradient, for: .navigation)
    }
}

private struct ResultView: View {
    var summary: RemoteShotSummary?
    var next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let s = summary, s.hasLaunchData {
                    Text("\(s.club.uppercased()) · CARRY")
                        .font(.system(size: 11, weight: .heavy).width(.expanded))
                        .foregroundStyle(WatchPalette.plasma)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(RemoteFormat.number(s.carry))
                            .font(.system(size: 64, weight: .black).width(.compressed))
                            .monospacedDigit()
                            .foregroundStyle(WatchPalette.floodlight)
                        Text(s.distanceUnit)
                            .font(.system(size: 14, weight: .bold).width(.condensed))
                            .foregroundStyle(WatchPalette.mist)
                    }
                    HStack(spacing: 0) {
                        stat("BALL", RemoteFormat.number(s.ballSpeed), s.speedUnit)
                        stat("LAUNCH", RemoteFormat.number(s.launchAngle, digits: 1), "°")
                        if s.smash != nil { stat("SMASH", RemoteFormat.number(s.smash, digits: 2), "") }
                    }
                } else if let s = summary {
                    Image(systemName: s.shotsFound > 0 ? "questionmark.circle" : "figure.golf")
                        .font(.system(size: 30))
                        .foregroundStyle(WatchPalette.caution)
                    Text(s.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .multilineTextAlignment(.center)
                    if let tempo = s.tempo {
                        stat("TEMPO", RemoteFormat.number(tempo, digits: 1), ":1")
                    }
                }
                if let s = summary {
                    Text(footnote(s))
                        .font(.system(size: 11))
                        .foregroundStyle(WatchPalette.mist)
                        .multilineTextAlignment(.center)
                }
                Button(action: next) {
                    Label("Next shot", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .bold))
                }
                .tint(WatchPalette.plasma)
                .padding(.top, 4)
            }
        }
        .containerBackground(WatchPalette.turf.gradient, for: .navigation)
    }

    private func footnote(_ s: RemoteShotSummary) -> String {
        var parts = ["\(s.practiceSwings) practice swing\(s.practiceSwings == 1 ? "" : "s")"]
        if s.savedToPhotos { parts.append("saved to Photos") }
        return parts.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .heavy).width(.expanded))
                .foregroundStyle(WatchPalette.mist)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 22, weight: .heavy).width(.compressed))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WatchPalette.mist)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ErrorView: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(WatchPalette.caution)
                Text(message)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                Button("OK", action: dismiss).tint(WatchPalette.plasma)
            }
        }
    }
}

private struct ClubPickerSheet: View {
    var current: String?
    var select: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let clubs = ["Driver", "3 Wood", "5 Wood", "Hybrid", "4 Iron", "5 Iron", "6 Iron", "7 Iron",
                                "8 Iron", "9 Iron", "Pitching Wedge", "Gap Wedge", "Sand Wedge", "Lob Wedge"]

    var body: some View {
        List(Self.clubs, id: \.self) { club in
            Button {
                select(club)
                dismiss()
            } label: {
                HStack {
                    Text(club)
                    Spacer()
                    if club == current { Image(systemName: "checkmark").foregroundStyle(WatchPalette.plasma) }
                }
            }
        }
        .navigationTitle("Club")
    }
}
