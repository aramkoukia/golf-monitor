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
                .task { applyDebugLaunch() }
        }
    }

    @MainActor
    private func applyDebugLaunch() {
        if DebugLaunch.flag("reset") { store.deleteAll() }
        if DebugLaunch.flag("skipOnboarding") { settings.hasCompletedOnboarding = true }
        if let tab = DebugLaunch.initialTab { router.tab = tab }
        if DebugLaunch.flag("demo") {
            DemoData.seedIfEmpty(store, settings: settings)
        }
        if DebugLaunch.value("studio") == "first" {
            Task { @MainActor in
                // Bundled clips are analyzed asynchronously; wait for one.
                for _ in 0..<120 {
                    if let shot = store.shots.first(where: \.hasMedia) {
                        router.openStudio(shot.id)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }
}
