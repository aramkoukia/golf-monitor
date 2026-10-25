import SwiftUI
import UIKit

// MARK: - Design tokens — "Night Flight"

/// A floodlit driving range at 9 pm, seen from the TV truck: an OLED-black
/// canvas, deep floodlit turf, one white-hot Plasma tracer as the only hero
/// colour, broadcast lower-thirds and F1 timing conventions for data.
/// Liquid Glass is reserved for the thin control layer that floats over
/// video; content (tiles, cards, charts, lists) sits on solid surfaces.
/// Every screen pulls colours, type, spacing and motion from here.
enum Theme {

    // MARK: Colors

    enum Palette {
        // Canvas & surfaces
        /// App canvas, camera letterbox. Near-black, never pure #000.
        static let void = Color(hex: 0x050607)
        /// Content surfaces: metric tiles, shot cards, rows, lower-third slab.
        static let carbon = Color(hex: 0x0D1114)
        /// Elevated panels, chart plot areas, iOS 18 sheet fallback.
        static let graphite = Color(hex: 0x161C21)
        /// Hairlines, chart grid, inactive tracks, unlit start lights.
        static let steel = Color(hex: 0x26303A)
        /// Floodlit-turf tint for mesh gradients and the flight slab ground.
        static let turfNight = Color(hex: 0x0A2E22)
        /// Floodlight "pool" hotspot inside meshes.
        static let turfLit = Color(hex: 0x12513B)

        // Text
        /// Primary text, hero numerals, the ball.
        static let floodlight = Color(hex: 0xF2F5F3)
        /// Secondary text, units, axis labels, ALL-CAPS eyebrows.
        static let mist = Color(hex: 0x9AA5B0)
        /// Tertiary / disabled text.
        static let dim = Color(hex: 0x5C6772)

        // Signal colours
        /// Brand = your ball. Tracer glow, Record, the ONE primary CTA per screen.
        static let plasma = Color(hex: 0xFF5A1F)
        /// White-hot tracer core, comet head, impact flashes. Never text.
        static let tracerCore = Color(hex: 0xFFE7B0)
        /// Good / ready: ball locked, level OK, session best (F1 green).
        static let ion = Color(hex: 0x3DF5A6)
        /// All-time personal best (F1 purple). Always with a crown/star + label.
        static let apexViolet = Color(hex: 0xA45CFF)
        /// Warnings only: tracking glitch, low light, rough-guide metrics.
        static let caution = Color(hex: 0xFFC53D)
        /// Errors and destructive actions only, always with icon + label.
        static let signalRed = Color(hex: 0xFF3B30)

        // Data viz (validated for dark mode / colour-vision deficiency)
        static let chartYou = Color(hex: 0xEA5202)
        static let chartReference = Color(hex: 0x2D95D3)
        static let chartCompare = Color(hex: 0xD9468F)
        /// Ordinal club-family ramp: woods, hybrids, irons, wedges.
        static let clubRamp: [Color] = [Color(hex: 0xFFCDAE), Color(hex: 0xFF9C6C),
                                        Color(hex: 0xFA6A2D), Color(hex: 0xD6480B)]

        static let hairline = Color.white.opacity(0.08)
        static let hairlineStrong = Color.white.opacity(0.16)
    }

    /// Rating → signal colour. Red is reserved for errors, so "needs work"
    /// is amber.
    static func color(for rating: MetricRating) -> Color {
        switch rating {
        case .tour: return Palette.ion
        case .good: return Palette.floodlight
        case .needsWork: return Palette.caution
        case .unrated: return Palette.mist
        }
    }

    /// Club family colour (ordinal ramp; driver shares the woods tone).
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

    /// Numbers get their own voice (SF Pro Compressed/Condensed, heavy) as in
    /// broadcast graphics; labels are SF Pro Expanded caps; timecodes SF Mono.
    enum Font {
        /// Range-glance carry readable from 3 m (≥120 pt).
        static func mega(_ size: CGFloat = 180) -> SwiftUI.Font {
            .system(size: size, weight: .black).width(.compressed)
        }
        /// Hero numeral (ball speed, carry on the reveal).
        static func hero(_ size: CGFloat = 96) -> SwiftUI.Font {
            .system(size: size, weight: .heavy).width(.compressed)
        }
        /// Metric value inside tiles.
        static func metric(_ size: CGFloat = 34) -> SwiftUI.Font {
            .system(size: size, weight: .bold).width(.condensed)
        }
        /// ALL-CAPS eyebrow label ("BALL SPEED").
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold).width(.expanded)
        static let unit = SwiftUI.Font.system(size: 13, weight: .bold).width(.condensed)
        /// In-content display header (system nav titles stay native).
        static let display = SwiftUI.Font.system(size: 30, weight: .heavy).width(.expanded)
        static let title = SwiftUI.Font.system(size: 22, weight: .bold).width(.expanded)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        /// Frame counters, timecodes, axis ticks: "F142 · 0.592 s · 240 fps".
        static let mono = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
    }

    // MARK: Motion

    /// Fast UI, cinematic hero; stillness while recording; respect Reduce Motion.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.28)
        static let smooth = Animation.smooth(duration: 0.45)
        static let bouncy = Animation.bouncy(duration: 0.5)
        /// Hero reveal choreography (≤ 1.6 s total, skippable).
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
/// Never fire haptics while recording (they can disturb the capture).
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
