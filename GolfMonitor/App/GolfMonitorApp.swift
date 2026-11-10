import SwiftUI

/// GolfMonitor — a camera-only launch monitor and swing analyzer.
/// Everything runs on the phone: no server, no account, all models on device.
@main
struct GolfMonitorApp: App {
    @StateObject private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.store)
                .environmentObject(services.settings)
                .environmentObject(services.router)
                .environmentObject(services)
                .environmentObject(services.camera)
                .environmentObject(services.session)
                .environmentObject(services.remote.link)
                .preferredColorScheme(.dark)
                .task { applyDebugLaunch() }
                .onOpenURL { url in
                    if url.scheme == "golfmonitor" { services.router.tab = .range }
                }
        }
        .onChange(of: scenePhase) { _, phase in services.scenePhaseChanged(phase) }
    }

    @MainActor
    private func applyDebugLaunch() {
        let store = services.store, settings = services.settings, router = services.router
        if DebugLaunch.flag("reset") { store.deleteAll() }
        if DebugLaunch.flag("skipOnboarding") { settings.hasCompletedOnboarding = true }
        if let tab = DebugLaunch.initialTab { router.tab = tab }
        services.tabChanged()
        if DebugLaunch.flag("demo") { DemoData.seedIfEmpty(store, settings: settings) }
        if DebugLaunch.value("studio") == "first" {
            Task { @MainActor in
                for _ in 0..<120 {
                    if let shot = store.shots.first(where: \.hasMedia) {
                        router.openStudio(shot.id)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        // -gm.autostart [seconds]: start a recording once the camera is live,
        // and stop it after `seconds` (default 4) — end-to-end checks in the Simulator.
        if DebugLaunch.flag("autostart") {
            let seconds = DebugLaunch.value("autostart").flatMap(Double.init) ?? 4
            Task { @MainActor in
                var waited = 0
                while !services.camera.isReadyToRecord, waited < 60 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waited += 1
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                services.session.start(origin: .phone)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                services.session.stop(origin: .phone)
            }
        }
    }
}
