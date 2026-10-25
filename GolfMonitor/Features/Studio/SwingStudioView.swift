import SwiftUI

/// Full-screen Swing Studio for one shot. (Stub — owned by the Swing Studio workstream.)
struct SwingStudioView: View {
    let route: StudioRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            NightRangeBackground()
            VStack {
                EmptyStateView(icon: "figure.golf", title: "Swing Studio", message: "Coming soon.")
                Button("Close") { dismiss() }.buttonStyle(GlassButtonStyle())
            }
        }
    }
}
