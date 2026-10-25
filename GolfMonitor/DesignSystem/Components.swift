import SwiftUI

// MARK: - Labels

/// Small all-caps tracked label ("BALL SPEED").
struct CapsLabel: View {
    var text: String
    var color: Color = Theme.Palette.textSecondary

    init(_ text: String, color: Color = Theme.Palette.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.label)
            .tracking(1.4)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Section header with optional trailing action.
struct SectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold).width(.expanded))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
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

// MARK: - Numbers

/// Animated numeric value with a unit, e.g. "142 mph". Rolls digits when the
/// value changes (numericText content transition).
struct NumberText: View {
    var value: Double?
    var digits: Int = 0
    var unit: String = ""
    var font: Font = Theme.Font.metric()
    var unitFont: Font = Theme.Font.unit
    var color: Color = Theme.Palette.textPrimary
    /// Prefix for estimated values ("~").
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
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if !unit.isEmpty {
                Text(unit)
                    .font(unitFont)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The big hero readout (ball speed / carry) that counts up from zero.
struct HeroNumber: View {
    var label: String
    var value: Double?
    var unit: String
    var digits: Int = 0
    var accent: Color = Theme.Palette.volt
    var size: CGFloat = 96

    @State private var shown: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            CapsLabel(label, color: accent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value == nil ? "—" : shown.formatted(.number.precision(.fractionLength(digits))))
                    .font(Theme.Font.hero(size))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.Palette.textPrimary, Theme.Palette.textPrimary.opacity(0.75)],
                                       startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText(value: shown))
                Text(unit)
                    .font(.system(size: size * 0.22, weight: .bold).width(.condensed))
                    .foregroundStyle(accent)
            }
            .glow(accent, radius: 22, opacity: 0.25)
        }
        .onAppear { animate(to: value) }
        .onChange(of: value) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value.map { String(format: "%.\(digits)f", $0) } ?? "unknown") \(unit)")
    }

    private func animate(to target: Double?) {
        guard let target, target.isFinite else { return }
        shown = 0
        withAnimation(.easeOut(duration: 0.9)) { shown = target }
    }
}

// MARK: - Metric tile

/// Compact glass tile: label, big value, unit, optional delta and badge.
struct MetricTile: View {
    var label: String
    var value: Double?
    var unit: String = ""
    var digits: Int = 0
    /// Marks model estimates (carry, apex…) with "~" and an EST badge.
    var isEstimate: Bool = false
    /// Signed difference vs a reference (session average, tour…).
    var delta: Double? = nil
    var deltaDigits: Int = 0
    var tint: Color = Theme.Palette.textPrimary
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                CapsLabel(label)
                Spacer(minLength: 0)
                if isEstimate {
                    Text("EST")
                        .font(.system(size: 9, weight: .heavy).width(.expanded))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Theme.Palette.textTertiary, lineWidth: 1))
                }
            }
            NumberText(value: value, digits: digits, unit: unit, color: tint, prefix: isEstimate ? "~" : "")
            if let delta, delta.isFinite {
                DeltaBadge(delta: delta, digits: deltaDigits, unit: unit)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.Radius.m)
    }
}

/// "+4 mph" / "−2.1°" pill.
struct DeltaBadge: View {
    var delta: Double
    var digits: Int = 0
    var unit: String = ""
    /// When false, a negative delta is the good direction (e.g. offline).
    var higherIsBetter: Bool = true

    var body: some View {
        let good = higherIsBetter ? delta >= 0 : delta <= 0
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "±")
        Text("\(sign)\(abs(delta).formatted(.number.precision(.fractionLength(digits))))\(unit.isEmpty ? "" : " " + unit)")
            .font(.system(size: 11, weight: .bold).width(.condensed))
            .monospacedDigit()
            .foregroundStyle(good ? Theme.Palette.volt : Theme.Palette.flare)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((good ? Theme.Palette.volt : Theme.Palette.flare).opacity(0.12), in: Capsule())
    }
}

// MARK: - Range bar

/// Horizontal bar showing a value against a tour range (shaded band).
struct RangeBar: View {
    var value: Double
    var range: ClosedRange<Double>
    /// Visible domain; defaults to the range padded by its width.
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
                Capsule().fill(Theme.Palette.surfaceHigh)
                Capsule()
                    .fill(Theme.Palette.volt.opacity(0.22))
                    .frame(width: max(4, x(range.upperBound) - x(range.lowerBound)))
                    .offset(x: x(range.lowerBound))
                Circle()
                    .fill(Theme.color(for: rating))
                    .frame(width: 12, height: 12)
                    .glow(Theme.color(for: rating), radius: 6, opacity: 0.7)
                    .offset(x: min(max(x(value) - 6, 0), geo.size.width - 12))
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Buttons

/// Primary call-to-action: volt capsule with glow.
struct NeonButtonStyle: ButtonStyle {
    var color: Color = Theme.Palette.volt
    var foreground: Color = .black

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold).width(.expanded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(color, in: Capsule())
            .glow(color, radius: configuration.isPressed ? 6 : 14, opacity: 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// Secondary glass button.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
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
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint ?? Theme.Palette.textPrimary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
    }
}

// MARK: - Chips

/// Selectable capsule chip (clubs, filters).
struct Chip: View {
    var title: String
    var isSelected: Bool
    var color: Color = Theme.Palette.volt
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold).width(.condensed))
                .foregroundStyle(isSelected ? .black : Theme.Palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        Capsule().fill(color).glow(color, radius: 8, opacity: 0.4)
                    } else {
                        Capsule().fill(Color.white.opacity(0.06))
                            .overlay(Capsule().strokeBorder(Theme.Palette.stroke, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.snappy, value: isSelected)
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
                .foregroundStyle(Theme.Palette.volt)
                .glow(Theme.Palette.volt, radius: 18, opacity: 0.4)
                .symbolEffect(.pulse, options: .repeating)
            Text(title)
                .font(.system(size: 22, weight: .heavy).width(.expanded))
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(NeonButtonStyle())
                    .frame(maxWidth: 260)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xl)
    }
}
