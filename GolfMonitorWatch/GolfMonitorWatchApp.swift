import SwiftUI

/// GolfMonitor on Apple Watch: a remote for the iPhone on the tripod —
/// live camera preview, start / stop, and your numbers on your wrist.
@main
struct GolfMonitorWatchApp: App {
    @StateObject private var model = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environmentObject(model)
                .tint(WatchPalette.plasma)
        }
    }
}
