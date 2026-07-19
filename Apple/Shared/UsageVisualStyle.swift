import SwiftUI

enum WatchQuotaSeverity: Equatable, Sendable {
    case abundant
    case healthy
    case caution
    case low
    case critical

    init(remainingPercent: Double) {
        if remainingPercent <= 10 {
            self = .critical
        } else if remainingPercent <= 20 {
            self = .low
        } else if remainingPercent <= 40 {
            self = .caution
        } else if remainingPercent <= 60 {
            self = .healthy
        } else {
            self = .abundant
        }
    }

    var color: Color {
        switch self {
        case .abundant: .blue
        case .healthy: .green
        case .caution: .orange
        case .low: .red
        case .critical: Color(red: 0.72, green: 0, blue: 0.04)
        }
    }

    var glowColor: Color {
        self == .critical ? Color.red.opacity(0.28) : .clear
    }

    var glowRadius: CGFloat {
        self == .critical ? 4 : 0
    }

    var showsCriticalWarning: Bool { self == .critical }
}

enum UsagePalette {
    static func primary(remainingPercent: Double) -> Color {
        WatchQuotaSeverity(remainingPercent: remainingPercent).color
    }

    static func secondary(remainingPercent: Double) -> Color {
        WatchQuotaSeverity(remainingPercent: remainingPercent).color
    }

    static func arcFraction(remainingPercent: Double) -> Double {
        if remainingPercent <= 0 { return 1 }
        return min(max(remainingPercent / 100, 0), 1)
    }
}

struct ConcentricQuotaRing<Center: View>: View {
    let primaryRemaining: Double
    let secondaryRemaining: Double?
    let size: CGFloat
    let isStale: Bool
    private let center: Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var criticalPulse = false

    init(
        primaryRemaining: Double,
        secondaryRemaining: Double? = nil,
        size: CGFloat,
        isStale: Bool = false,
        @ViewBuilder center: () -> Center
    ) {
        self.primaryRemaining = primaryRemaining
        self.secondaryRemaining = secondaryRemaining
        self.size = size
        self.isStale = isStale
        self.center = center()
    }

    var body: some View {
        ZStack {
            if let secondaryRemaining {
                ring(
                    remaining: secondaryRemaining,
                    color: UsagePalette.secondary(remainingPercent: secondaryRemaining),
                    diameter: size * 0.96,
                    lineWidth: max(2.5, size * 0.052)
                )
            }

            ring(
                remaining: primaryRemaining,
                color: UsagePalette.primary(remainingPercent: primaryRemaining),
                diameter: secondaryRemaining == nil ? size * 0.9 : size * 0.76,
                lineWidth: max(3, size * 0.066)
            )

            center
                .frame(width: size * 0.38, height: size * 0.38)
        }
        .frame(width: size, height: size)
        .opacity(isStale ? 0.62 : 1)
        .accessibilityHidden(true)
        .onAppear(perform: updateCriticalPulse)
        .onChange(of: hasCriticalSeverity) { _, _ in updateCriticalPulse() }
    }

    private func ring(
        remaining: Double,
        color: Color,
        diameter: CGFloat,
        lineWidth: CGFloat
    ) -> some View {
        let severity = WatchQuotaSeverity(remainingPercent: remaining)
        let fraction = UsagePalette.arcFraction(remainingPercent: remaining)
        return ZStack {
            Circle()
                .stroke(
                    .secondary.opacity(severity.showsCriticalWarning ? 0 : 0.16),
                    lineWidth: lineWidth
                )
            if severity.showsCriticalWarning {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        Color.red.opacity(0.28),
                        style: StrokeStyle(lineWidth: lineWidth + 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(criticalPulse ? 1.15 : 1.03)
                    .blur(radius: criticalPulse ? 2.5 : 3.5)
                    .shadow(color: Color.red.opacity(0.28), radius: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(severity.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: severity.glowColor, radius: severity.glowRadius / 3)
                .shadow(color: severity.glowColor.opacity(0.9), radius: severity.glowRadius * 0.7)
                .shadow(color: severity.glowColor.opacity(0.72), radius: severity.glowRadius)
            } else {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var hasCriticalSeverity: Bool {
        WatchQuotaSeverity(remainingPercent: primaryRemaining).showsCriticalWarning
            || secondaryRemaining.map {
                WatchQuotaSeverity(remainingPercent: $0).showsCriticalWarning
            } == true
    }

    private func updateCriticalPulse() {
        criticalPulse = false
        guard hasCriticalSeverity else { return }
        if reduceMotion {
            criticalPulse = true
        } else {
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                criticalPulse = true
            }
        }
    }
}

struct QuotaWindowTag: View {
    let window: WatchQuotaWindowSnapshot
    let role: Role
    var includesPercentage = false

    enum Role: Equatable {
        case primary
        case secondary
    }

    private var color: Color {
        switch role {
        case .primary:
            UsagePalette.primary(remainingPercent: window.remainingPercent)
        case .secondary:
            UsagePalette.secondary(remainingPercent: window.remainingPercent)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(accessibilityText)
    }

    private var label: String {
        let tag = window.compactDurationTag ?? (role == .primary ? "LIMIT" : "MORE")
        guard includesPercentage else { return tag }
        return "\(tag) \(Int(window.remainingPercent.rounded()))%"
    }

    private var accessibilityText: String {
        let windowName = window.durationDescription ?? (role == .primary ? "Primary limit" : "Secondary limit")
        return "\(windowName), \(Int(window.remainingPercent.rounded())) percent remaining"
    }
}

extension WatchQuotaWindowSnapshot {
    var compactDurationTag: String? {
        guard let seconds = windowDurationSeconds else { return nil }
        if seconds.isMultiple(of: 86_400) { return "\(seconds / 86_400)D" }
        if seconds.isMultiple(of: 3_600) { return "\(seconds / 3_600)H" }
        if seconds.isMultiple(of: 60) { return "\(seconds / 60)M" }
        return "\(seconds)S"
    }

    var durationDescription: String? {
        guard let seconds = windowDurationSeconds else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 86_400 ? [.day] : seconds >= 3_600 ? [.hour] : [.minute]
        formatter.maximumUnitCount = 1
        return formatter.string(from: TimeInterval(seconds))
    }
}

extension WatchQuotaSnapshot {
    var effectiveRemainingPercent: Double {
        min(primary.remainingPercent, secondary?.remainingPercent ?? 100)
    }

    var constrainingWindow: WatchQuotaWindowSnapshot {
        guard let secondary, secondary.remainingPercent < primary.remainingPercent else {
            return primary
        }
        return secondary
    }

    var constrainingWindowRole: QuotaWindowTag.Role {
        guard let secondary, secondary.remainingPercent < primary.remainingPercent else {
            return .primary
        }
        return .secondary
    }
}
