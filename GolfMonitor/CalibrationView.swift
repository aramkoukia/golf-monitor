import SwiftUI
import AVFoundation
import Combine

/// Setup tab: phone-to-ball distance, camera position, ball-diameter
/// calibration (pixel→meter scale), and display-unit settings.
struct CalibrationView: View {
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var camera = CameraManager()

    @State private var calibration = Calibration.load()
    @State private var distanceText: String = ""
    @State private var useFeet = false
    @State private var detectionMessage: String?
    @State private var isDetecting = false
    @State private var showSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera position") {
                    Picker("View", selection: .constant(0)) {
                        Text("Side view (supported)").tag(0)
                    }
                    .pickerStyle(.segmented)
                    Text("Mount the phone on a tripod 90° to your target line, level with the ball, in landscape.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Distance: phone → ball") {
                    HStack {
                        TextField("Distance", text: $distanceText)
                            .keyboardType(.decimalPad)
                        Picker("", selection: $useFeet) {
                            Text("meters").tag(false)
                            Text("feet").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    Text("Measure with the range's markers or pace it off. Used as a sanity check on the ball detection below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Ball calibration") {
                    if camera.isSessionRunning {
                        CameraPreviewView(previewLayer: camera.previewLayer)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button(isDetecting ? "Detecting…" : "Detect ball in frame") {
                        detectBall()
                    }
                    .disabled(isDetecting || !camera.isAuthorized)

                    if let msg = detectionMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if calibration.isCalibrated {
                        HStack {
                            Text("Scale")
                            Spacer()
                            Text(String(format: "%.0f px / meter", calibration.pixelsPerMeter))
                                .monospacedDigit()
                        }
                        if let d = calibration.ballDiameterPx {
                            HStack {
                                Text("Ball diameter in frame")
                                Spacer()
                                Text(String(format: "%.1f px", d))
                                    .monospacedDigit()
                            }
                        }
                        // Manual override for tricky lighting.
                        VStack(alignment: .leading) {
                            Text("Fine-tune scale")
                                .font(.caption)
                            Slider(value: $calibration.pixelsPerMeter, in: 100...4000, step: 10)
                        }
                    } else {
                        Text("Not calibrated yet — frame the ball in the center and tap Detect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Display units") {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases, id: \.self) { u in Text(u.rawValue).tag(u) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Distance", selection: $settings.distanceUnit) {
                        ForEach(DistanceUnit.allCases, id: \.self) { u in Text(u.rawValue).tag(u) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Save setup") { save() }
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Setup")
            .onAppear {
                let cal = Calibration.load()
                calibration = cal
                useFeet = cal.useFeet
                distanceText = String(format: "%.1f", useFeet ? cal.distanceToBallMeters * 3.28084 : cal.distanceToBallMeters)
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
            .alert("Setup saved", isPresented: $showSaved) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    // MARK: Actions

    private func detectBall() {
        guard camera.isSessionRunning else {
            detectionMessage = "Camera isn't running yet — grant access and wait a moment."
            return
        }
        isDetecting = true
        detectionMessage = nil
        camera.captureSingleFrame { buffer in
            let diameter = TrackingEngine.detectBallDiameter(in: buffer)
            DispatchQueue.main.async {
                self.isDetecting = false
                guard let d = diameter, d > 6, d < 400 else {
                    self.detectionMessage = "No ball found. Center a clean white ball in good light and try again."
                    return
                }
                self.calibration.ballDiameterPx = d
                self.calibration.pixelsPerMeter = d / Calibration.golfBallDiameterMeters
                self.calibration.isCalibrated = true
                self.detectionMessage = String(
                    format: "Ball detected: %.1f px → %.0f px/m. Tap Save setup.",
                    d, self.calibration.pixelsPerMeter
                )
            }
        }
    }

    private func save() {
        let entered = Double(distanceText.replacingOccurrences(of: ",", with: ".")) ?? 3.0
        calibration.distanceToBallMeters = useFeet ? entered / 3.28084 : entered
        calibration.useFeet = useFeet
        calibration.save()
        showSaved = true
    }
}

