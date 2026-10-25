import Foundation

/// What the Range screen is being used for. `.free` is normal practice;
/// practice games (Practice tab) hand in a context with a target and a
/// per-shot scorer, and the Range screen renders the game banner, calls
/// `onShot` after each saved shot and shows/speaks the returned feedback.
struct RangeSessionContext: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String = ""
    /// PracticeGame identifier, nil for free practice.
    var gameID: String? = nil
    /// Current target, asked before each shot (nil = no target).
    var currentTarget: () -> RangeTarget? = { nil }
    /// Called after each saved shot; returns feedback to display/speak.
    var onShot: (Shot) -> RangeFeedback? = { _ in nil }
    /// True once the game is complete (Range then shows the summary action).
    var isFinished: () -> Bool = { false }
    /// Called when the user ends the game from the Range screen.
    var onFinish: () -> Void = {}

    static var free: RangeSessionContext { RangeSessionContext(title: "Free Practice") }
    var isFree: Bool { gameID == nil }
}

struct RangeTarget: Hashable {
    /// e.g. "150 YDS", "MAX SPEED", "TEMPO 3:1".
    var label: String
    var carryYards: Double? = nil
    var club: Club? = nil
    var toleranceYards: Double? = nil
}

struct RangeFeedback: Hashable {
    var headline: String
    var detail: String = ""
    var points: Int? = nil
    /// Short sentence for the voice announcer, if any.
    var spoken: String? = nil
    var isSuccess: Bool = false
}
