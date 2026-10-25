import Foundation

/// Launch arguments for simulator screenshots and UI checks, e.g.
///   xcrun simctl launch <udid> com.example.golfmonitor -gm.demo -gm.tab insights
///
/// -gm.demo            seed demo shots (synthetic history + bundled CC0 clips) if the library is empty
/// -gm.reset           wipe the library before seeding
/// -gm.skipOnboarding  mark onboarding complete
/// -gm.tab <tab>       start on a tab: range | library | insights | practice | profile
/// -gm.studio first    open the newest shot that has media in the Swing Studio
/// -gm.screen <name>   feature-specific deep link (each workstream documents its own)
enum DebugLaunch {
    static let arguments = ProcessInfo.processInfo.arguments

    static func flag(_ name: String) -> Bool { arguments.contains("-gm.\(name)") }

    static func value(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: "-gm.\(name)"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static var initialTab: AppTab? { value("tab").flatMap(AppTab.init(rawValue:)) }
    static var screen: String? { value("screen") }
}
