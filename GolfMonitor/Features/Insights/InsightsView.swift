import SwiftUI

/// Insights tab: analytics dashboard. (Stub — owned by the Library & Insights workstream.)
struct InsightsView: View {
    var body: some View {
        ZStack {
            NightRangeBackground()
            EmptyStateView(icon: "chart.xyaxis.line", title: "Insights", message: "Coming soon.")
        }
    }
}
