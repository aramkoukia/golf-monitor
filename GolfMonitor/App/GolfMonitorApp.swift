import SwiftUI

/// GolfMonitor — a budget iPhone launch monitor for the driving range.
/// Side-view slow-mo video → ball/club tracking → shot metrics.
@main
struct GolfMonitorApp: App {
    @StateObject private var store = ShotStore()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                SessionView()
                    .tabItem {
                        Label("Session", systemImage: "camera.fill")
                    }
                ShotHistoryView()
                    .tabItem {
                        Label("History", systemImage: "list.bullet")
                    }
                CalibrationView()
                    .tabItem {
                        Label("Setup", systemImage: "gearshape.fill")
                    }
            }
            .environmentObject(store)
            .environmentObject(settings)
        }
    }
}
