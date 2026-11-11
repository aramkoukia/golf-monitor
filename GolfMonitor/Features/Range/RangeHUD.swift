import SwiftUI

// Control-layer pieces of the Range screen (glass over the live camera).

// MARK: - Record button

/// The one primary control: a Plasma disc that breathes while ready and
/// morphs into a stop square (with the time-limit ring) while recording.
struct RecordButton: View {
    var isRecording: Bool
    var isEnabled: Bool
    /// A recording started now is likely to be caught and measured: the ring
    /// turns green (readable from the tee).
    var isReady = false
    /// 0...1 of the recording time limit used.
    var limitFraction: Double
    var action: () -> Void

    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(isReady && !isRecording ? Theme.Palette.ion : Color.white.opacity(0.9),
                            lineWidth: isReady && !isRecording ? 5 : 4)
                    .frame(width: 84, height: 84)
                    .shadow(color: isReady && !isRecording ? Theme.Palette.ion.opacity(0.7) : .clear, radius: 8)
                if isRecording {
                    Circle()
                        .trim(from: 0, to: limitFraction)
                        .stroke(Theme.Palette.signalRed, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 84, height: 84)
                }
                RoundedRectangle(cornerRadius: isRecording ? 9 : 34, style: .continuous)
                    .fill(isRecording ? Theme.Palette.signalRed : Theme.Palette.plasma)
                    .frame(width: isRecording ? 34 : 68, height: isRecording ? 34 : 68)
                    .shadow(color: (isRecording ? Theme.Palette.signalRed : Theme.Palette.plasma).opacity(0.7),
                            radius: breathe && !isRecording ? 22 : 8)
                    .scaleEffect(breathe && !isRecording ? 1.04 : 1)
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(Theme.Motion.bouncy, value: isRecording)
        .animation(Theme.Motion.snappy, value: isReady)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : (isReady ? "Start recording, ready to swing" : "Start recording"))
        .accessibilityHint(isRecording ? "Stops and analyzes your session" : "Records until you stop: set up, practice swings, then hit")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Top bar

struct RangeTopBar: View {
    var status: CaptureStatus
    var format: CaptureFormat?
    var isRecording: Bool
    var watch: WatchLinkStatus

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.9), radius: 4)
                Text(statusText)
                    .font(.system(size: 11, weight: .heavy).width(.expanded))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.floodlight)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassCapsule()

            if let format {
                Text(format.badge)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.floodlight)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glassCapsule()
                    .accessibilityLabel("Recording at \(Int(format.fps)) frames per second")
            }
            Spacer(minLength: 0)
            WatchBadge(watch: watch)
        }
    }

    private var statusText: String {
        if isRecording { return "REC" }
        switch status {
        case .running: return "LIVE"
        case .starting, .idle: return "STARTING"
        case .denied: return "NO CAMERA"
        case .interrupted: return "PAUSED"
        case .failed: return "ERROR"
        }
    }

    private var statusColor: Color {
        if isRecording { return Theme.Palette.signalRed }
        switch status {
        case .running: return Theme.Palette.ion
        case .starting, .idle, .interrupted: return Theme.Palette.caution
        case .denied, .failed: return Theme.Palette.signalRed
        }
    }
}

struct WatchBadge: View {
    var watch: WatchLinkStatus

    var body: some View {
        if watch.isPaired {
            HStack(spacing: 6) {
                Image(systemName: watch.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: watch.isReachable)
                if !watch.isReachable {
                    Circle().fill(Theme.Palette.dim).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(watch.isReachable ? Theme.Palette.ion : Theme.Palette.mist)
            .frame(height: 34)
            .padding(.horizontal, 11)
            .glassCapsule()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(watch.summary)
        }
    }
}

// MARK: - Club & view controls

struct ClubMenuChip: View {
    @Binding var club: Club

    var body: some View {
        Menu {
            Picker("Club", selection: $club) {
                ForEach(Club.allCases) { c in Text(c.rawValue).tag(c) }
            }
        } label: {
            VStack(spacing: 1) {
                Text(club.shortName)
                    .font(.system(size: 20, weight: .black).width(.compressed))
                    .foregroundStyle(Theme.Palette.floodlight)
                Text("CLUB")
                    .font(.system(size: 8, weight: .bold).width(.expanded))
                    .foregroundStyle(Theme.Palette.mist)
            }
            .frame(width: 58, height: 58)
            .glassCapsule(interactive: true, clear: true)
        }
        .accessibilityLabel("Club, \(club.rawValue)")
    }
}

struct CameraViewToggle: View {
    @Binding var view: CameraView

    var body: some View {
        Button {
            Haptics.select()
            view = view == .faceOn ? .downTheLine : .faceOn
        } label: {
            VStack(spacing: 1) {
                Image(systemName: view == .faceOn ? "person.fill" : "arrow.up.forward")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.Palette.floodlight)
                    .contentTransition(.symbolEffect(.replace))
                Text(view.shortTitle)
                    .font(.system(size: 8, weight: .bold).width(.expanded))
                    .foregroundStyle(Theme.Palette.mist)
            }
            .frame(width: 58, height: 58)
            .glassCapsule(interactive: true, clear: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera view, \(view.title)")
        .accessibilityHint("Face-on measures ball flight; down-the-line analyzes the swing")
    }
}

// MARK: - Routine strip

/// The four-beat routine, which also acts as live feedback while recording:
/// Start → Practice swings → Hit → Stop.
struct RoutineStrip: View {
    var isRecording: Bool
    var swings: Int
    var shots: Int
    var ballLocked: Bool

    var body: some View {
        HStack(spacing: 0) {
            step(icon: "record.circle", title: isRecording ? "REC" : "START", done: isRecording, active: !isRecording)
            divider
            step(icon: "figure.golf", title: swings > 0 ? "\(swings) SWING\(swings == 1 ? "" : "S")" : "PRACTICE",
                 done: swings > 0, active: isRecording && shots == 0)
            divider
            step(icon: shots > 0 ? "checkmark.seal.fill" : "circle.dotted",
                 title: shots > 0 ? "SHOT ✓" : (ballLocked ? "HIT" : "TEE UP"),
                 done: shots > 0, active: isRecording && shots == 0 && swings > 0)
            divider
            step(icon: "stop.circle", title: "STOP", done: false, active: isRecording && shots > 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .glassCapsule()
        .animation(Theme.Motion.snappy, value: swings)
        .animation(Theme.Motion.snappy, value: shots)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(Theme.Palette.hairlineStrong).frame(width: 10, height: 1)
    }

    private func step(icon: String, title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: active)
            Text(title)
                .font(.system(size: 10, weight: .heavy).width(.condensed))
                .tracking(0.4)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .foregroundStyle(done ? Theme.Palette.ion : (active ? Theme.Palette.floodlight : Theme.Palette.floodlight.opacity(0.62)))
        .padding(.horizontal, 7)
    }
}

// MARK: - Recording clock

struct RecordingClock: View {
    var startedAt: Date
    var limit: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.Palette.signalRed)
                    .frame(width: 10, height: 10)
                    .opacity(Int(elapsed) % 2 == 0 ? 1 : 0.35)
                Text(RemoteFormat.clock(elapsed))
                    .font(.system(size: 22, weight: .heavy).width(.compressed))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.floodlight)
                    .contentTransition(.numericText())
                Text("/ \(RemoteFormat.clock(limit))")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.floodlight.opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassCapsule(tint: Theme.Palette.signalRed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording, \(Int(elapsed)) seconds")
        }
    }
}

/// Soft red pulse around the screen edge while recording, so it's obvious
/// from the mat that the phone is capturing.
struct RecordingVignette: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 44, style: .continuous)
            .strokeBorder(Theme.Palette.signalRed.opacity(pulse ? 0.85 : 0.35), lineWidth: pulse ? 7 : 4)
            .blur(radius: 6)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { pulse = true; return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
