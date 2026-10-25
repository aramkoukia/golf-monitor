import Foundation
import SwiftUI

/// Top-level tabs.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case range
    case library
    case insights
    case practice
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .range: return "Range"
        case .library: return "Swings"
        case .insights: return "Insights"
        case .practice: return "Practice"
        case .profile: return "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .range: return "scope"
        case .library: return "film.stack"
        case .insights: return "chart.xyaxis.line"
        case .practice: return "target"
        case .profile: return "person.crop.circle"
        }
    }
}

/// Identifies a shot to present in the Swing Studio.
struct StudioRoute: Identifiable, Hashable {
    var shotID: UUID
    /// Optional second shot for side-by-side compare.
    var compareShotID: UUID? = nil
    var id: UUID { shotID }
}

/// App-wide navigation state, injected as an environment object.
/// Any screen can switch tabs, open a shot in the Swing Studio, or hand a
/// practice game to the Range screen.
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .range
    /// Non-nil presents the Swing Studio full-screen.
    @Published var studio: StudioRoute? = nil
    /// Practice game the Range screen should run next (PracticeGame id).
    @Published var pendingGameID: String? = nil
    /// What the Range screen is doing (free practice or a game).
    @Published var rangeContext: RangeSessionContext = .free

    func openStudio(_ shotID: UUID, compareWith other: UUID? = nil) {
        studio = StudioRoute(shotID: shotID, compareShotID: other)
    }

    func startGame(_ gameID: String) {
        pendingGameID = gameID
        tab = .range
    }

    /// Hands a practice game to the Range screen and switches to it.
    func startPractice(_ context: RangeSessionContext) {
        rangeContext = context
        pendingGameID = context.gameID
        tab = .range
    }

    func endPractice() {
        rangeContext = .free
        pendingGameID = nil
    }
}
