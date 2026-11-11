import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ImportedSwingVideo: Identifiable, Transferable {
    let url: URL
    var id: URL { url }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("golfmonitor-import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedSwingVideo(url: destination)
        }
    }
}

enum SwingImportError: LocalizedError {
    case noVideo
    case noVideoTrack
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .noVideo: return "No video was selected."
        case .noVideoTrack: return "The selected file doesn't contain a video track."
        case .invalidDuration: return "The selected video has an invalid duration."
        }
    }
}

struct SwingImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var session: RangeSessionController
    @EnvironmentObject private var settings: SettingsStore

    let videoURL: URL
    @State private var cameraView: CameraView = .faceOn
    @State private var handedness: Handedness = .right
    @State private var progress = ProcessingProgress.start
    @State private var isProcessing = false
    @State private var importedCount: Int?
    @State private var warning: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Label("Selected swing video", systemImage: "video")
                    Text("Analysis runs on this device. Your original video is not modified. If a ball strike isn’t trackable, the result will be swing-only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Swing details") {
                    Picker("Club", selection: $session.club) {
                        ForEach(Club.allCases) { club in Text(club.rawValue).tag(club) }
                    }
                    Picker("Camera view", selection: $cameraView) {
                        ForEach(CameraView.allCases) { view in Text(view.title).tag(view) }
                    }
                    Picker("Handedness", selection: $handedness) {
                        ForEach(Handedness.allCases) { hand in Text(hand.title).tag(hand) }
                    }
                }

                if isProcessing {
                    Section("Analyzing") {
                        ProgressView(value: progress.fraction) {
                            Text(progress.detail)
                        }
                    }
                }

                if let importedCount {
                    Section {
                        Label("Added \(importedCount) swing\(importedCount == 1 ? "" : "s") to your library",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Palette.ion)
                        if let warning {
                            Text(warning).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if let error {
                    Section("Couldn’t analyze video") {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Swing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importedCount == nil ? "Cancel" : "Close") { dismiss() }
                        .disabled(isProcessing)
                }
                if importedCount == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Analyze") { analyze() }
                            .fontWeight(.semibold)
                            .disabled(isProcessing)
                    }
                }
            }
            .interactiveDismissDisabled(isProcessing)
        }
        .onAppear {
            cameraView = settings.cameraView
            handedness = settings.handedness
        }
        .onDisappear {
            try? FileManager.default.removeItem(at: videoURL)
        }
    }

    private func analyze() {
        isProcessing = true
        error = nil
        warning = nil
        Task {
            do {
                let workingURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("golfmonitor-analysis-\(UUID().uuidString).\(videoURL.pathExtension)")
                try FileManager.default.copyItem(at: videoURL, to: workingURL)
                defer { try? FileManager.default.removeItem(at: workingURL) }

                let asset = AVURLAsset(url: workingURL)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw SwingImportError.noVideoTrack
                }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw SwingImportError.invalidDuration }
                let nominalFPS = try await track.load(.nominalFrameRate)
                let fps = nominalFPS.isFinite && nominalFPS > 0 ? Double(nominalFPS) : 30

                let context = SessionContext(club: session.club, cameraView: cameraView, handedness: handedness,
                                             saveShotsToPhotos: false, saveSessionToPhotos: false,
                                             source: .imported)
                let outcome = try await SessionProcessor(store: store).process(
                    RecordedSession(videoURL: workingURL, duration: duration, fps: fps, timeline: nil),
                    context: context
                ) { update in
                    progress = update
                }
                importedCount = outcome.shots.count
                if !outcome.warnings.isEmpty {
                    warning = outcome.warnings.joined(separator: "\n")
                }
            } catch {
                self.error = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
