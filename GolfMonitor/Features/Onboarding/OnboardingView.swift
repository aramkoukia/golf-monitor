import SwiftUI

/// First-run onboarding. (Stub — owned by the Practice/Profile/Shell workstream.)
struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            NightRangeBackground()
            VStack(spacing: 24) {
                EmptyStateView(icon: "figure.golf", title: "GolfMonitor", message: "Your phone is now a launch monitor.")
                Button("Get started") { settings.hasCompletedOnboarding = true }
                    .buttonStyle(NeonButtonStyle())
                    .padding(.horizontal, 40)
            }
        }
    }
}
