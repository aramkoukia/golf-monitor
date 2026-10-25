import SwiftUI

// MARK: - Glass surfaces (Liquid Glass on iOS 26, materials on iOS 18)

extension View {
    /// A floating glass card. Uses Liquid Glass on iOS 26+ and a dark
    /// material with a hairline gradient stroke on earlier systems.
    func glassCard(cornerRadius: CGFloat = Theme.Radius.m, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Glass capsule for chips, HUD pills and floating controls.
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassCapsuleModifier(tint: tint, interactive: interactive))
    }

    /// Soft colored glow behind content (neon look).
    func glow(_ color: Color = Theme.Palette.volt, radius: CGFloat = 16, opacity: Double = 0.55) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
            .shadow(color: color.opacity(opacity * 0.5), radius: radius / 3)
    }
}

private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            if let tint {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .fill(tint.opacity(0.12))
                            }
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1)
                }
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.35)) }
        if interactive { g = g.interactive() }
        return g
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: .capsule)
        } else {
            content
                .background {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay { if let tint { Capsule().fill(tint.opacity(0.18)) } }
                }
                .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.4)) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups glass shapes so they blend/morph together on iOS 26
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

/// Slowly drifting dark mesh gradient used behind non-camera screens.
struct NightRangeBackground: View {
    var accent: Color = Theme.Palette.volt
    var animated: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let s = Float(sin(t / 7)) * 0.08
            let c = Float(cos(t / 9)) * 0.08
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + s, 0], [1, 0],
                    [0, 0.5 + c], [0.5 + c, 0.45 + s], [1, 0.5 - s],
                    [0, 1], [0.5 - s, 1], [1, 1],
                ],
                colors: [
                    Theme.Palette.ink, Color(hex: 0x07140F), Theme.Palette.ink,
                    Color(hex: 0x081A14), accent.opacity(0.10), Color(hex: 0x06121A),
                    Theme.Palette.ink, Color(hex: 0x050C10), Theme.Palette.ink,
                ]
            )
        }
        .ignoresSafeArea()
    }
}
