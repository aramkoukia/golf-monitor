import Foundation
import Photos

/// Saves videos into the user's photo library (add-only access: the app
/// never reads the library). Behind a protocol so the session pipeline can
/// be tested without touching Photos.
protocol PhotoLibrarySaving {
    func saveVideo(at url: URL) async throws
}

struct PhotoLibrarySaver: PhotoLibrarySaving {
    enum SaveError: LocalizedError {
        case accessDenied
        case failed

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Allow GolfMonitor to add to Photos in Settings → Privacy → Photos."
            case .failed: return "The video couldn't be saved to Photos."
            }
        }
    }

    func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.accessDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success { continuation.resume() } else { continuation.resume(throwing: error ?? SaveError.failed) }
            }
        }
    }
}
