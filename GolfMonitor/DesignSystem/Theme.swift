import SwiftUI
import UIKit

// MARK: - Design tokens — "Gold Standard"

/// A premium launch monitor: OLED-black canvas, molten-gold brand colour
/// (pulled directly from the app icon's crown and ball), warm-gold tracer,
/// Liquid Glass for the thin control layer over video.
/// The palette draws from the icon: deep charcoal-black background,
/// rich metallic gold (#C9922A) as the single hero colour, a bright
/// champagne highlight (#F5D98B) for glows and tracer cores.
enum Theme {

    // MARK: Colors

    enum Palette {
        // Canvas & surfaces
        /// App canvas, camera letterbox. Matches the icon's background black.
        static let void = Color(hex: 0x0A0A0B)
        /// Content surfaces: metric tiles, shot cards, rows, lower-third slab.
        static let carbon = Color(hex: 0x111113)
        /// Elevated panels, chart plot areas, iOS 26 sheet fallback.
        static let graphite = Color(hex: 0x1C1C1F)
        /// Hairlines, chart grid, inactive tracks.
        static let steel = Color(hex: 0x2C2C30)
        /// Warm near-black tint for mesh gradients (replaces turf green).
        static let turfNight = Color(hex: 0x14100A)
        /// Subtle gold-ember pool inside mesh gradients.
        static let turfLit = Color(hex: 0x2A1E0A)

        // Text
        /// Primary text, hero numerals.
        static let floodlight = Color(hex: 0xF2F0ED)
        /// Secondary text, units, axis labels.
        static let mist = Color(hex: 0x9A9690)
        /// Tertiary / disabled text.
        static let dim = Color(hex: 0x5C5854)

        // Brand — the gold
        /// Brand = molten gold. CTAs, tracer, record button, the ONE hero
        /// colour. Sampled from the icon's orbital ring: #C9922A.
        static let plasma = Color(hex: 0xC9922A)
        /// Bright champagne highlight: tracer core, comet head, impact flash.
        /// Sampled from the top specular of the icon's ball: #F5D98B.
        static let tracerCore = Color(hex: 0xF5D98B)
        /// Deep amber-gold for glows and tints at lower opacity.
        static let goldDeep = Color(hex: 0x8A5E10)

        // Functional signal colours — kept distinct from brand gold
        /// Good / ready: ball locked, level OK, session best (stays green —
        /// it's a safety/status signal, not a brand colour).
        static let ion = Color(hex: 0x3DF5A6)
        /// All-time personal best (stays violet).
        static let apexViolet = Color(hex: 0xA45CFF)
        /// Warnings only: tracking glitch, low light.
        static let caution = Color(hex: 0xFFC53D)
        /// Errors and destructive actions only.
        static let signalRed = Color(hex: 0xFF3B30)

        // Data viz
        static let chartYou = Color(hex: 0xC9922A)          // gold for "you"
        static let chartReference = Color(hex: 0x2D95D3)
        static let chartCompare = Color(hex: 0xD9468F)
        /// Ordinal club-family ramp: woods → wedges, warm gold tones.
        static let clubRamp: [Color] = [Color(hex: 0xF5D98B), Color(hex: 0xDAAD50),
                                        Color(hex: 0xC9922A), Color(hex: 0x8A5E10)]

        static let hairline = Color.white.opacity(0.07)
        static let hairlineStrong = Color.white.opacity(0.14)
    }

    /// Rating → signal colour.
    static func color(for rating: MetricRating) -> Color {
        switch rating {
        case .tour: return Palette.ion
        case .good: return Palette.floodlight
        case .needsWork: return Palette.caution
        case .unrated: return Palette.mist
        }
    }

    /// Club family colour (ordinal ramp; driver shares the brightest gold).
    static func color(for club: Club) -> Color {
        switch club.category {
        case .driver, .wood: return Palette.clubRamp[0]
        case .hybrid: return Palette.clubRamp[1]
        case .iron: return Palette.clubRamp[2]
        case .wedge: return Palette.clubRamp[3]
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
        static let s: CGFloat = 10
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: Typography

    enum Font {
        static func mega(_ size: CGFloat = 180) -> SwiftUI.Font {
            .system(size: size, weight: .black).width(.compressed)
        }
        static func hero(_ size: CGFloat = 96) -> SwiftUI.Font {
            .system(size: size, weight: .heavy).width(.compressed)
        }
        static func metric(_ size: CGFloat = 34) -> SwiftUI.Font {
            .system(size: size, weight: .bold).width(.condensed)
        }
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold).width(.expanded)
        static let unit = SwiftUI.Font.system(size: 13, weight: .bold).width(.condensed)
        static let display = SwiftUI.Font.system(size: 30, weight: .heavy).width(.expanded)
        static let title = SwiftUI.Font.system(size: 22, weight: .bold).width(.expanded)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let mono = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
    }

    // MARK: Motion

    enum Motion {
        static let snappy = Animation.snappy(duration: 0.28)
        static let smooth = Animation.smooth(duration: 0.45)
        static let bouncy = Animation.bouncy(duration: 0.5)
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
