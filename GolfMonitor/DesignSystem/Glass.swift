import SwiftUI

// MARK: - Surfaces
//
// Two layers, never mixed:
//  • Content layer — tiles, cards, charts, lists: SOLID Carbon/Graphite.
//  • Control layer — HUD pills, floating buttons over video: Liquid Glass
//    (iOS 26) or a dark material fallback (iOS 18). No glass on glass.

extension View {
    /// Solid content card (Carbon with a hairline). Use for tiles, shot
    /// cards, chart panels and list rows.
    func contentCard(cornerRadius: CGFloat = Theme.Radius.m, elevated: Bool = false) -> some View {
        background(elevated ? Theme.Palette.graphite : Theme.Palette.carbon,
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            }
    }

    /// Floating glass panel for the control layer (HUD clusters, toolbars
    /// over video). Tint only the primary action.
    func glassCard(cornerRadius: CGFloat = Theme.Radius.m, tint: Color? = nil,
                   interactive: Bool = false, clear: Bool = false) -> some View {
        modifier(GlassShapeModifier(shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)),
                                    tint: tint, interactive: interactive, clear: clear))
    }

    /// Glass capsule for HUD pills and floating controls.
    func glassCapsule(tint: Color? = nil, interactive: Bool = false, clear: Bool = false) -> some View {
        modifier(GlassShapeModifier(shape: AnyShape(Capsule()), tint: tint, interactive: interactive, clear: clear))
    }

    /// Additive neon glow (tracer, hero numerals, record button).
    func glow(_ color: Color = Theme.Palette.plasma, radius: CGFloat = 16, opacity: Double = 0.55) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
            .shadow(color: color.opacity(opacity * 0.5), radius: radius / 3)
    }
}

private struct GlassShapeModifier: ViewModifier {
    var shape: AnyShape
    var tint: Color?
    var interactive: Bool
    var clear: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay { if clear { shape.fill(Color.black.opacity(0.35)) } }
                        .overlay { if let tint { shape.fill(tint.opacity(0.22)) } }
                }
                .overlay { shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5) }
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g: Glass = clear ? .clear : .regular
        if let tint { g = g.tint(tint.opacity(0.5)) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups glass shapes so they blend and morph together on iOS 26
/// (GlassEffectContainer); a plain container elsewhere.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Backgrounds

/// "Floodlight Mesh": a slow 3×3 mesh (Void, Turf Night, a Turf Lit pool)
/// behind screens that don't show the camera. Frozen under Reduce Motion.
struct FloodlightBackground: View {
    var animated: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !animated || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let s = Float(sin(t / 9)) * 0.06
            let c = Float(cos(t / 11)) * 0.06
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.55 + c], [0.55 + s, 0.62 + c], [1, 0.5 - s],
                    [0, 1], [0.5 + c, 1], [1, 1],
                ],
                colors: [
                    Theme.Palette.void, Theme.Palette.void, Theme.Palette.void,
                    Theme.Palette.void, Theme.Palette.turfNight, Theme.Palette.void,
                    Theme.Palette.turfNight, Theme.Palette.turfLit.opacity(0.7), Theme.Palette.turfNight,
                ]
            )
        }
        .ignoresSafeArea()
    }
}

/// Back-compat name used by early stubs.
typealias NightRangeBackground = FloodlightBackground
