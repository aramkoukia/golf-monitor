import Foundation
import Combine
import SwiftUI
import UIKit

/// Builds and wires the app's long-lived objects once, at launch:
///
///     camera frames ─▶ SceneMonitor (motion + ball lock) ─▶ RangeSessionController
///                  └─▶ WatchPreviewStreamer ─▶ PhoneRemoteServer ◀─▶ Apple Watch
///
/// Also decides when the camera runs: while the app is in the foreground and
/// the Range tab is open, a watch is connected, or a recording is under way.
/// The screen is kept awake whenever the camera is live (tripod use).
@MainActor
final class AppServices: ObservableObject {
    let store: ShotStore
    let settings: SettingsStore
    let router: AppRouter
    let monitor: SceneMonitor
    let camera: CameraController
    let session: RangeSessionController
    let remote: PhoneRemoteServer

    private var isAppActive = true
    /// The app is hosting unit tests: no camera, no watch link.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init(store: ShotStore = ShotStore(), settings: SettingsStore = SettingsStore(), router: AppRouter = AppRouter(),
         remote: PhoneRemoteServer? = nil) {
        self.store = store
        self.settings = settings
        self.router = router
        let remote = remote ?? .shared
        self.remote = remote
        monitor = SceneMonitor()
        camera = CameraController(consumers: [monitor, remote.streamer])
        let processor = SessionProcessor(store: store)
        session = RangeSessionController(camera: camera, monitor: monitor, processor: processor,
                                         settings: settings, store: store)
        session.router = router
        session.announcer = ShotAnnouncer()
        session.cameraUnavailableReason = { [weak self] in self?.cameraUnavailableReason }
        session.onChange = { [weak remote] in remote?.publish() }

        monitor.onSnapshot = { [weak self] snapshot in self?.session.updateScene(snapshot) }
        camera.onExposureChange = { [weak self] in self?.monitor.refreshReferences() }
        camera.onCriticalPressure = { [weak self] in self?.session.handleCriticalPressure() }
        Haptics.enabled = settings.hapticsEnabled

        remote.handler = session
        session.setAppActive(UIApplication.shared.applicationState != .background)
        guard !Self.isHostingTests else { return }
        remote.activate()
        applyShutter()
    }

    // MARK: Lifecycle inputs

    func scenePhaseChanged(_ phase: ScenePhase) {
        isAppActive = phase != .background
        session.setAppActive(isAppActive)
        updateCamera()
    }

    func tabChanged() { updateCamera() }
    func watchReachabilityChanged() { updateCamera() }

    func cameraStatusChanged() {
        session.cameraDidChange()
        updateCamera()
    }

    func applyShutter() {
        camera.setShutter(settings.shutterMode.seconds)
    }

    // MARK: Camera demand

    var wantsCamera: Bool {
        guard isAppActive else { return false }
        return router.tab == .range || remote.link.isReachable || camera.isRecording || session.phase.isRecording
    }

    private func updateCamera() {
        guard !Self.isHostingTests else { return }
        let wanted = wantsCamera
        UIApplication.shared.isIdleTimerDisabled = wanted
        if wanted {
            if camera.status == .idle || camera.status == .interrupted { camera.start() }
        } else if !camera.isRecording {
            camera.stop()
        }
    }

    var cameraUnavailableReason: String? {
        switch camera.status {
        case .running: return nil
        case .idle, .starting: return "Camera starting…"
        case .denied: return "Camera access is off — enable it in Settings › GolfMonitor."
        case .interrupted: return "The camera is in use by another app."
        case .failed(let reason): return reason
        }
    }
}
