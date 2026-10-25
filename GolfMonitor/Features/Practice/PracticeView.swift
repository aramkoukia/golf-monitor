import SwiftUI

/// Practice tab: games, drills, goals. (Stub — owned by the Practice/Profile/Shell workstream.)
struct PracticeView: View {
    var body: some View {
        ZStack {
            NightRangeBackground()
            EmptyStateView(icon: "target", title: "Practice", message: "Coming soon.")
        }
    }
}
