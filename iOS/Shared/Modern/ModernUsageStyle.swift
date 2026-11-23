import SwiftUI

/// The Modern look's usage colours, the same as the Mac's: blue while plenty
/// is left, then green, orange, red, and deep red at 10% or less. They are
/// the system colours, so they follow light, dark and Increase Contrast.
enum ModernUsageColor {
    static func color(remainingPercent: Double) -> Color {
        let value = remainingPercent.isFinite ? remainingPercent : 0
        if value <= 10 { return Color(red: 0.72, green: 0, blue: 0.04) }
        if value <= 20 { return .red }
        if value <= 40 { return .orange }
        if value <= 60 { return .green }
        return .blue
    }

    /// How much of a ring or bar to fill. An empty window draws a full ring
    /// in its warning colour rather than disappearing.
    static func fillFraction(remainingPercent: Double) -> Double {
        let value = remainingPercent.isFinite ? remainingPercent : 0
        if value <= 0 { return 1 }
        return min(max(value / 100, 0.015), 1)
    }

    /// "62%"
    static func percent(_ remainingPercent: Double) -> String {
        let value = remainingPercent.isFinite ? remainingPercent : 0
        return "\(Int(min(max(value, 0), 100).rounded()))%"
    }
}

#if os(iOS)
/// The grouped page and its cards, as in Settings.
enum ModernPalette {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardRadius: CGFloat = 16
}
#endif

/// A limit drawn like the Mac's Modern rail: Activity-style rings on a
/// track tinted with each ring's own colour. Every tool is drawn at the same
/// outer size; a limit's second window is the outer ring and its first
/// window nests inside it, so a second window never shrinks the ring.
struct ModernQuotaRing<Center: View>: View {
    /// What's left of the limit's first window, in percent.
    let primary: Double
    /// What's left of its second window, when it has one.
    let secondary: Double?
    /// The ring's outer size, stroke included.
    let size: CGFloat
    /// Older readings draw fainter.
    var isDimmed = false
    private let center: Center

    init(
        primary: Double,
        secondary: Double? = nil,
        size: CGFloat,
        isDimmed: Bool = false,
        @ViewBuilder center: () -> Center
    ) {
        self.primary = primary
        self.secondary = secondary
        self.size = size
        self.isDimmed = isDimmed
        self.center = center()
    }

    /// The Mac draws a 58 pt ring with a 5 pt line and nests the first
    /// window at 45 pt; these keep those proportions at any size.
    static func outerLineWidth(size: CGFloat) -> CGFloat { size * 0.08 }
    static var innerScale: CGFloat { 45.0 / 58.0 }
    static var markScale: CGFloat { 23.0 / 58.0 }

    var body: some View {
        let outerLine = Self.outerLineWidth(size: size)
        let outerDiameter = size - outerLine
        let innerDiameter = outerDiameter * Self.innerScale
        ZStack {
            if let secondary {
                ring(remaining: secondary, diameter: outerDiameter, lineWidth: outerLine * 0.9)
                ring(remaining: primary, diameter: innerDiameter, lineWidth: outerLine)
            } else {
                ring(remaining: primary, diameter: outerDiameter, lineWidth: outerLine)
            }
            // One mark size for every tool, as on the Mac rail (23 pt in a
            // 58 pt ring), whether or not a second window nests the first.
            center
                .frame(width: size * Self.markScale, height: size * Self.markScale)
        }
        .frame(width: size, height: size)
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityHidden(true)
    }

    private func ring(remaining: Double, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        let color = ModernUsageColor.color(remainingPercent: remaining)
        return ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: ModernUsageColor.fillFraction(remainingPercent: remaining))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

extension ModernQuotaRing where Center == EmptyView {
    init(primary: Double, secondary: Double? = nil, size: CGFloat, isDimmed: Bool = false) {
        self.init(primary: primary, secondary: secondary, size: size, isDimmed: isDimmed) { EmptyView() }
    }
}

/// One usage window as a bar, as in the Mac's Modern window: the window's
/// length, a bar of what's left, the percentage in its colour, and when it
/// resets.
struct ModernQuotaBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var tagWidth: CGFloat = 30
    @ScaledMetric(relativeTo: .callout) private var percentWidth: CGFloat = 54
    @ScaledMetric(relativeTo: .caption) private var resetWidth: CGFloat = 70

    /// The window's length, such as "5H" or "7D".
    let tag: String?
    let remainingPercent: Double
    let resetAt: Date?

    var body: some View {
        let color = ModernUsageColor.color(remainingPercent: remainingPercent)
        let percent = ModernUsageColor.percent(remainingPercent)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let reset = ResetCountdown.phrase(until: resetAt, now: context.date)
            let tagLabel = Text(tag ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            let percentLabel = Text(percent)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
            let resetLabel = Text(reset ?? "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            let bar = ModernCapsuleBar(remainingPercent: remainingPercent, color: color)
                .frame(height: 8)

            let tagAndPercent = HStack(alignment: .firstTextBaseline, spacing: 8) {
                if tag != nil {
                    tagLabel.fixedSize(horizontal: false, vertical: true)
                }
                percentLabel
            }
            let stacked = VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        tagAndPercent
                        if reset != nil { resetLabel }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 4) {
                        tagAndPercent
                        if reset != nil {
                            resetLabel.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                bar
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    stacked
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            tagLabel
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: tagWidth, alignment: .leading)
                            bar.frame(minWidth: 40)
                            percentLabel.frame(minWidth: percentWidth, alignment: .trailing)
                            resetLabel
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: resetWidth, alignment: .leading)
                        }
                        stacked
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tag.map { Text("\($0) window") } ?? Text("Limit"))
            .accessibilityValue(Text("\(percent) left, \(ResetCountdown.accessibilityLabel(until: resetAt, now: context.date))"))
        }
    }
}

/// A rounded bar filled with what's left, on a track of its own colour.
struct ModernCapsuleBar: View {
    let remainingPercent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(color.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(color.gradient)
                        .frame(width: max(
                            geometry.size.height,
                            geometry.size.width * min(1, max(0, remainingPercent / 100))
                        ))
                }
        }
        .accessibilityHidden(true)
    }
}
