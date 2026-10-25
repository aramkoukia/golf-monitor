import SwiftUI

// MARK: - Labels

/// Small all-caps tracked eyebrow ("BALL SPEED"), SF Pro Expanded.
struct CapsLabel: View {
    var text: String
    var color: Color = Theme.Palette.mist

    init(_ text: String, color: Color = Theme.Palette.mist) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.label)
            .tracking(1.1)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// In-content section header with optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.floodlight)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.mist)
                }
            }
            Spacer()
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Provenance ("Honest Numbers")

/// Where a number comes from. Every metric shows its glyph.
enum Provenance: String, Codable {
    /// ● Measured from the video (ball speed, launch angle, tempo timing).
    case measured
    /// ◐ Modeled / estimated, shown with "~" (carry, apex, hang time, club speed).
    case modeled
    /// ○ Rough guide (offline from a face-on camera), amber.
    case roughGuide
    /// ⊘ Not measurable with a camera (spin).
    case notMeasurable

    var glyph: String {
        switch self {
        case .measured: return "●"
        case .modeled: return "◐"
        case .roughGuide: return "○"
        case .notMeasurable: return "⊘"
        }
    }

    var color: Color {
        switch self {
        case .measured: return Theme.Palette.floodlight
        case .modeled: return Theme.Palette.mist
        case .roughGuide: return Theme.Palette.caution
        case .notMeasurable: return Theme.Palette.dim
        }
    }

    var label: String {
        switch self {
        case .measured: return "Measured"
        case .modeled: return "Estimated"
        case .roughGuide: return "Rough guide"
        case .notMeasurable: return "Not measurable"
        }
    }

    /// Prefix shown before modeled values.
    var valuePrefix: String { self == .modeled || self == .roughGuide ? "~" : "" }
}

struct ProvenanceGlyph: View {
    var provenance: Provenance
    var body: some View {
        Text(provenance.glyph)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(provenance.color)
            .accessibilityLabel(provenance.label)
    }
}

// MARK: - Numbers

/// Animated numeric value with a unit on its baseline ("152 YDS").
struct NumberText: View {
    var value: Double?
    var digits: Int = 0
    var unit: String = ""
    var font: Font = Theme.Font.metric()
    var unitFont: Font = Theme.Font.unit
    var color: Color = Theme.Palette.floodlight
    var prefix: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let value, value.isFinite {
                Text(prefix + value.formatted(.number.precision(.fractionLength(digits))))
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: value))
            } else {
                Text("—")
                    .font(font)
                    .foregroundStyle(Theme.Palette.dim)
            }
            if !unit.isEmpty {
                Text(unit.uppercased())
                    .font(unitFont)
                    .foregroundStyle(Theme.Palette.mist)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Hero readout that counts up from zero on appear / value change.
struct HeroNumber: View {
    var label: String
    var value: Double?
    var unit: String
    var digits: Int = 0
    var size: CGFloat = 96
    var provenance: Provenance = .measured
    /// Session best → Ion, all-time PB → Apex Violet.
    var highlight: Color? = nil

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ProvenanceGlyph(provenance: provenance)
                CapsLabel(label, color: highlight ?? Theme.Palette.mist)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value == nil ? "—" : provenance.valuePrefix + shown.formatted(.number.precision(.fractionLength(digits))))
                    .font(Theme.Font.hero(size))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.floodlight)
                    .contentTransition(.numericText(value: shown))
                Text(unit.uppercased())
                    .font(.system(size: size * 0.2, weight: .bold).width(.condensed))
                    .foregroundStyle(highlight ?? Theme.Palette.mist)
            }
        }
        .onAppear { animate(to: value) }
        .onChange(of: value) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value.map { String(format: "%.\(digits)f", $0) } ?? "unknown") \(unit)")
    }

    private func animate(to target: Double?) {
        guard let target, target.isFinite else { return }
        if reduceMotion { shown = target; return }
        shown = 0
        withAnimation(.easeOut(duration: 0.9)) { shown = target }
    }
}

// MARK: - Metric tile

/// Solid content tile: eyebrow + provenance, big value + unit, optional delta.
struct MetricTile: View {
    var label: String
    var value: Double?
    var unit: String = ""
    var digits: Int = 0
    var provenance: Provenance = .measured
    /// Signed difference vs a reference (session average, tour…).
    var delta: Double? = nil
    var deltaDigits: Int = 0
    var higherIsBetter: Bool = true
    /// Session best → Ion, all-time PB → Apex Violet (adds a marker).
    var highlight: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ProvenanceGlyph(provenance: provenance)
                CapsLabel(label)
                Spacer(minLength: 0)
                if let highlight {
                    Image(systemName: highlight == Theme.Palette.apexViolet ? "crown.fill" : "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(highlight)
                }
            }
            NumberText(value: provenance == .notMeasurable ? nil : value, digits: digits, unit: unit,
                       color: Theme.Palette.floodlight, prefix: provenance.valuePrefix)
            if let delta, delta.isFinite {
                DeltaBadge(delta: delta, digits: deltaDigits, unit: unit, higherIsBetter: higherIsBetter)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .overlay(alignment: .leading) {
            if let highlight {
                Capsule().fill(highlight).frame(width: 3).padding(.vertical, 10)
            }
        }
    }
}

/// "+4 MPH" / "−2.1°" pill. Green-ish (Ion) when better, amber when worse.
struct DeltaBadge: View {
    var delta: Double
    var digits: Int = 0
    var unit: String = ""
    var higherIsBetter: Bool = true

    var body: some View {
        let good = higherIsBetter ? delta >= 0 : delta <= 0
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "±")
        let tint = good ? Theme.Palette.ion : Theme.Palette.caution
        Text("\(sign)\(abs(delta).formatted(.number.precision(.fractionLength(digits))))\(unit.isEmpty ? "" : " " + unit.uppercased())")
            .font(.system(size: 11, weight: .bold).width(.condensed))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Range bar

/// A value against a tour range (shaded band), e.g. for swing metrics.
struct RangeBar: View {
    var value: Double
    var range: ClosedRange<Double>
    var domain: ClosedRange<Double>? = nil
    var rating: MetricRating = .unrated

    var body: some View {
        GeometryReader { geo in
            let d = domain ?? {
                let w = max(range.upperBound - range.lowerBound, 1e-6)
                return (min(range.lowerBound - w, value) ... max(range.upperBound + w, value))
            }()
            let span = max(d.upperBound - d.lowerBound, 1e-6)
            let x: (Double) -> CGFloat = { CGFloat(($0 - d.lowerBound) / span) * geo.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.steel.opacity(0.6))
                Capsule()
                    .fill(Theme.Palette.ion.opacity(0.28))
                    .frame(width: max(4, x(range.upperBound) - x(range.lowerBound)))
                    .offset(x: x(range.lowerBound))
                Circle()
                    .fill(Theme.color(for: rating))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.Palette.void, lineWidth: 2))
                    .offset(x: min(max(x(value) - 6, 0), geo.size.width - 12))
            }
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityValue("\(value.formatted()) , tour range \(range.lowerBound.formatted()) to \(range.upperBound.formatted())")
    }
}

// MARK: - Buttons

/// The one primary CTA per screen: Plasma capsule.
struct PlasmaButtonStyle: ButtonStyle {
    var color: Color = Theme.Palette.plasma

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold).width(.expanded))
            .foregroundStyle(Theme.Palette.void)
            .padding(.horizontal, 24)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(color, in: Capsule())
            .glow(color, radius: configuration.isPressed ? 4 : 12, opacity: 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// Back-compat name for early stubs.
typealias NeonButtonStyle = PlasmaButtonStyle

/// Secondary button on glass (control layer) — or a solid Graphite pill.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.Palette.floodlight)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassCapsule(interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// Round icon button on glass (HUD controls).
struct GlassIconButton: View {
    var systemName: String
    var size: CGFloat = 44
    var tint: Color? = nil
    var accessibilityLabel: String? = nil
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint ?? Theme.Palette.floodlight)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
        .accessibilityLabel(accessibilityLabel ?? systemName)
    }
}

// MARK: - Chips

/// Selectable capsule chip (clubs, filters) on the content layer.
struct Chip: View {
    var title: String
    var isSelected: Bool
    var color: Color = Theme.Palette.floodlight
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold).width(.condensed))
                .foregroundStyle(isSelected ? Theme.Palette.void : Theme.Palette.floodlight)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        Capsule().fill(color)
                    } else {
                        Capsule().fill(Theme.Palette.graphite)
                            .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.snappy, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.Palette.plasma)
                .glow(Theme.Palette.plasma, radius: 18, opacity: 0.35)
            Text(title)
                .font(Theme.Font.title)
                .foregroundStyle(Theme.Palette.floodlight)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.mist)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PlasmaButtonStyle())
                    .frame(maxWidth: 260)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xl)
    }
}
