import SwiftUI

/// Tab shell. The Range tab is the camera; the others are the library,
/// charts, practice games and settings.
struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var watchLink: WatchLinkStatus
    /// Onboarding waits for the launch intro: a full-screen cover would sit
    /// on top of it.
    var introFinished = true

    var body: some View {
        TabView(selection: $router.tab) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    content(for: tab)
                }
            }
        }
        .tint(Theme.Palette.plasma)
        .fullScreenCover(item: $router.studio) { route in
            SwingStudioView(route: route)
        }
        // Each full-screen cover gets its own host view: two covers on the
        // same view don't present reliably.
        .background {
            Color.clear
                .fullScreenCover(isPresented: Binding(get: { introFinished && !settings.hasCompletedOnboarding },
                                                      set: { settings.hasCompletedOnboarding = !$0 })) {
                    OnboardingView()
                }
        }
        .onChange(of: router.tab) { _, _ in services.tabChanged() }
        .onChange(of: camera.status) { _, _ in services.cameraStatusChanged() }
        .onChange(of: watchLink.isReachable) { _, _ in services.watchReachabilityChanged() }
        .onChange(of: settings.shutterMode) { _, _ in services.applyShutter() }
        .onChange(of: settings.hapticsEnabled) { _, on in Haptics.enabled = on }
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .range: RangeView()
        case .library: ShotLibraryView()
        case .insights: InsightsView()
        case .practice: PracticeView()
        case .profile: ProfileView()
        }
    }
}
