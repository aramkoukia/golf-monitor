import SwiftUI

/// Profile tab: player, capture, Photos, units, data and about.
/// Everything is stored on the phone (UserDefaults + Documents).
struct ProfileView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var watch: WatchLinkStatus
    @State private var confirmDelete = false
    @State private var export: ExportItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $settings.playerName)
                    Picker("Swing", selection: $settings.handedness) {
                        ForEach(Handedness.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("Player") }

                Section {
                    Picker("Camera position", selection: $settings.cameraView) {
                        ForEach(CameraView.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Shutter", selection: $settings.shutterMode) {
                        ForEach(ShutterMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Recording limit", selection: $settings.maxRecordingMinutes) {
                        ForEach(SettingsStore.recordingLimitOptions, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Speak results", isOn: $settings.voiceReadout)
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Face-on measures ball speed, launch and carry; down-the-line analyzes the swing. A fast shutter (1/2000) freezes the ball — use Auto in dim light.")
                }

                Section {
                    Toggle("Save shot videos to Photos", isOn: $settings.saveShotsToPhotos)
                    Toggle("Also save the full recording", isOn: $settings.saveSessionToPhotos)
                        .disabled(!settings.saveShotsToPhotos && !settings.saveSessionToPhotos)
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Each analyzed shot (address to finish, 240 fps) is added to your photo library. The full recording includes setup and practice swings and can be large.")
                }

                Section {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Distance", selection: $settings.distanceUnit) {
                        ForEach(DistanceUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } header: { Text("Units") }

                Section {
                    LabeledContent("Status", value: watch.summary)
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Open GolfMonitor on your watch to see the camera, start and stop recording, and get your numbers on your wrist. Keep the iPhone app open on the tripod.")
                }

                Section {
                    LabeledContent("Shots", value: "\(store.shots.count)")
                    LabeledContent("Video storage", value: ByteCountFormatter.string(fromByteCount: store.mediaBytes(), countStyle: .file))
                    Button("Export shots (CSV)") {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GolfMonitor-shots.csv")
                        try? store.csvString().write(to: url, atomically: true, encoding: .utf8)
                        export = ExportItem(url: url)
                    }
                    Button("Delete all shots", role: .destructive) { confirmDelete = true }
                } header: { Text("Data") }

                Section {
                    LabeledContent("Ball detector", value: BundledModel.golfDetector.isAvailable ? "On device" : "Missing")
                    LabeledContent("Body pose", value: "Apple Vision · on device")
                    LabeledContent("Network", value: "Never used")
                } header: {
                    Text("Privacy & AI")
                } footer: {
                    Text("All analysis runs on your iPhone with bundled Core ML models (golf-ball detector fine-tuned from Ultralytics YOLO, AGPL-3.0) and Apple Vision. Nothing is uploaded; there is no account and no server.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FloodlightBackground(animated: false))
            .navigationTitle("Profile")
            .confirmationDialog("Delete every shot and video?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
            }
            .sheet(item: $export) { item in ShareSheet(items: [item.url]) }
        }
    }

    private struct ExportItem: Identifiable {
        var url: URL
        var id: URL { url }
    }
}
