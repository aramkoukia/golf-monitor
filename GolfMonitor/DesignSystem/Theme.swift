import SwiftUI
import UIKit

// MARK: - Design tokens

/// "Night Range" design language: a cinematic, dark-first UI with one loud
/// volt accent, broadcast-style condensed numerals and glass surfaces.
/// Every screen pulls colors, type and spacing from here — no ad-hoc values.
enum Theme {

    // MARK: Colors

    enum Palette {
        /// App background (near-black with a faint green cast).
        static let ink = Color(hex: 0x05080A)
        /// Raised surfaces (cards when glass is unavailable).
        static let surface = Color(hex: 0x0D1216)
        static let surfaceHigh = Color(hex: 0x151C22)
        static let stroke = Color.white.opacity(0.08)
        static let strokeStrong = Color.white.opacity(0.16)

        /// Primary accent — "volt" lime. Buttons, focus, the ball tracer.
        static let volt = Color(hex: 0xC6FF3D)
        /// Secondary accent — ice cyan. Club path, secondary data series.
        static let ice = Color(hex: 0x3DD9FF)
        /// Warnings, impact markers, "needs work" ratings.
        static let flare = Color(hex: 0xFF5C3A)
        /// Personal bests, achievements.
        static let gold = Color(hex: 0xFFC83D)
        static let violet = Color(hex: 0x9C7BFF)
        static let pink = Color(hex: 0xFF4FA3)
        static let fairway = Color(hex: 0x1F8A4C)

        static let textPrimary = Color(hex: 0xF3F6F8)
        static let textSecondary = Color(hex: 0x95A3AE)
        static let textTertiary = Color(hex: 0x5A6670)

        /// Ordered categorical series for charts (club colors etc.).
        static let series: [Color] = [volt, ice, violet, gold, pink, flare,
                                      Color(hex: 0x4BE3A0), Color(hex: 0x6E8BFF)]
    }

    static func color(for rating: MetricRating) -> Color {
        switch rating {
        case .tour: return Palette.volt
        case .good: return Palette.ice
        case .needsWork: return Palette.flare
        case .unrated: return Palette.textSecondary
        }
    }

    static func color(for club: Club) -> Color {
        switch club.category {
        case .driver: return Palette.volt
        case .wood: return Palette.ice
        case .hybrid: return Palette.violet
        case .iron: return Palette.gold
        case .wedge: return Palette.pink
        }
    }

    // MARK: Spacing & shape

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let s: CGFloat = 12
        static let m: CGFloat = 20
        static let l: CGFloat = 28
        static let xl: CGFloat = 36
    }

    // MARK: Typography

    enum Font {
        /// Broadcast-style hero numeral (ball speed, carry).
        static func hero(_ size: CGFloat = 88) -> SwiftUI.Font {
            .system(size: size, weight: .heavy, design: .default).width(.compressed)
        }
        /// Large metric value inside tiles.
        static func metric(_ size: CGFloat = 34) -> SwiftUI.Font {
            .system(size: size, weight: .bold, design: .default).width(.condensed)
        }
        /// Small all-caps label above values ("BALL SPEED").
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold, design: .default).width(.expanded)
        static let unit = SwiftUI.Font.system(size: 13, weight: .semibold, design: .rounded)
        static let title = SwiftUI.Font.system(size: 28, weight: .heavy, design: .default).width(.expanded)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let mono = SwiftUI.Font.system(size: 13, weight: .medium, design: .monospaced)
    }

    // MARK: Motion

    enum Motion {
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static let smooth = Animation.spring(response: 0.55, dampingFraction: 0.86)
        static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.62)
        static let reveal = Animation.spring(response: 0.7, dampingFraction: 0.8)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Haptics

/// Thin wrapper so call sites read as intent and respect the user setting.
enum Haptics {
    static var enabled = true

    static func tap() { impact(.light) }
    static func select() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
