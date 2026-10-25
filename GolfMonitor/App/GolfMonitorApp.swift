import SwiftUI

/// GolfMonitor — a camera-only launch monitor and swing analyzer.
/// Everything runs on the phone: no server, no account.
@main
struct GolfMonitorApp: App {
    @StateObject private var store = ShotStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(router)
                .preferredColorScheme(.dark)
        }
    }
}
