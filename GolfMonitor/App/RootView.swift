import SwiftUI

/// Tab shell. (Owned by the Practice/Profile/Shell workstream.)
struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: SettingsStore

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
        .fullScreenCover(isPresented: Binding(get: { !settings.hasCompletedOnboarding },
                                              set: { settings.hasCompletedOnboarding = !$0 })) {
            OnboardingView()
        }
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
