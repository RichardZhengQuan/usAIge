import SwiftUI
import WidgetKit

struct UsageWidgetEntryView: View {
    let entry: QuotaTimelineEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch entry.state {
            case let .current(snapshots):
                quotaContent(snapshots, status: .current)
            case let .stale(snapshots, oldestUpdate):
                quotaContent(snapshots, status: .stale(oldestUpdate))
            case .empty:
                HUDUnavailableView(
                    symbol: "plus",
                    title: "No limits",
                    message: "Open usAIge to add an AI tool."
                )
            case .error:
                HUDUnavailableView(
                    symbol: "exclamationmark",
                    title: "Unavailable",
                    message: "Open usAIge to refresh."
                )
            }
        }
        .containerBackground(for: .widget) {
            HUDWidgetBackground()
        }
    }

    @ViewBuilder
    private func quotaContent(
        _ snapshots: [QuotaSnapshot],
        status: WidgetQuotaStatus
    ) -> some View {
        switch family {
        case .systemSmall:
            HUDQuotaTile(
                snapshot: snapshots[0],
                status: status,
                now: entry.date,
                moduleSize: 100
            )
        default:
            mediumQuotaContent(snapshots, status: status)
        }
    }

    @ViewBuilder
    private func mediumQuotaContent(
        _ snapshots: [QuotaSnapshot],
        status: WidgetQuotaStatus
    ) -> some View {
        let visibleSnapshots = Array(snapshots.prefix(4))

        if visibleSnapshots.isEmpty {
            HUDUnavailableView(
                symbol: "plus",
                title: "No limits",
                message: "Open usAIge to add an AI tool."
            )
        } else {
            let showsFour = visibleSnapshots.count == 4

            HStack(spacing: showsFour ? 12 : 18) {
                ForEach(visibleSnapshots) { snapshot in
                    HUDQuotaTile(
                        snapshot: snapshot,
                        status: status,
                        now: entry.date,
                        moduleSize: showsFour ? 70 : 86
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private enum WidgetQuotaStatus {
    case current
    case stale(Date)

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    var accessibilityDescription: String {
        switch self {
        case .current:
            "Current cached data"
        case let .stale(date):
            "Stale cached data, oldest update \(WidgetQuotaAccessibility.date(date))"
        }
    }
}

private struct HUDQuotaTile: View {
    let snapshot: QuotaSnapshot
    let status: WidgetQuotaStatus
    let now: Date
    let moduleSize: CGFloat

    private var primarySeverity: WidgetQuotaSeverity {
        WidgetQuotaSeverity(remainingPercent: snapshot.remainingPercent)
    }

    private var secondarySeverity: WidgetQuotaSeverity? {
        snapshot.secondaryWindow.map {
            WidgetQuotaSeverity(remainingPercent: $0.remainingPercent)
        }
    }

    private var visibleSessionPhase: CodexSessionPhase? {
        guard let phase = snapshot.sessionStatus?.phase, phase.showsLight else { return nil }
        return phase
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let visibleSessionPhase {
                    HUDSessionStatusLight(
                        phase: visibleSessionPhase,
                        diameter: moduleSize * 0.97
                    )
                }

                if let secondary = snapshot.secondaryWindow {
                    HUDQuotaRing(
                        remainingPercent: secondary.remainingPercent,
                        severity: secondarySeverity ?? .abundant,
                        lineWidth: moduleSize * 0.05
                    )
                    .frame(width: moduleSize * 0.97, height: moduleSize * 0.97)
                }

                HUDQuotaRing(
                    remainingPercent: snapshot.remainingPercent,
                    severity: primarySeverity,
                    lineWidth: moduleSize * 0.067
                )
                .frame(
                    width: moduleSize * 0.77,
                    height: moduleSize * 0.77
                )

                WidgetToolMark(snapshot: snapshot, size: moduleSize * 0.38)
            }
            .frame(width: moduleSize, height: moduleSize)
            .opacity(status.isStale ? 0.58 : 1)

            HStack(spacing: 4) {
                HUDWindowTag(
                    text: WidgetQuotaFormat.resetTag(
                        resetAt: snapshot.resetAt,
                        fallback: snapshot.typeTag,
                        now: now
                    ),
                    severity: primarySeverity,
                    isCondensed: snapshot.secondaryWindow != nil
                )

                if let secondary = snapshot.secondaryWindow {
                    HUDWindowTag(
                        text: WidgetQuotaFormat.resetTag(
                            resetAt: secondary.resetAt,
                            fallback: secondary.typeTag,
                            now: now
                        ),
                        severity: secondarySeverity ?? .abundant,
                        isCondensed: true
                    )
                }
            }
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(WidgetQuotaAccessibility.snapshot(snapshot)), \(status.accessibilityDescription)"
        )
    }
}

private struct HUDSessionStatusLight: View {
    let phase: CodexSessionPhase
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(phase.color.opacity(0.82), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .blur(radius: 1)

            Circle()
                .stroke(phase.color.opacity(0.34), lineWidth: 7)
                .frame(width: diameter + 4, height: diameter + 4)
                .blur(radius: 4)
        }
        .accessibilityHidden(true)
    }
}

private struct HUDQuotaRing: View {
    let remainingPercent: Double
    let severity: WidgetQuotaSeverity
    let lineWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color.primary.opacity(colorScheme == .dark ? 0.085 : 0.11),
                    lineWidth: lineWidth
                )

            Circle()
                .trim(from: 0, to: WidgetQuotaFormat.arcFraction(remainingPercent))
                .stroke(
                    severity.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: severity.glowColor, radius: severity.glowRadius * 0.35)
                .shadow(color: severity.glowColor, radius: severity.glowRadius)
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}

private struct HUDWindowTag: View {
    let text: String
    let severity: WidgetQuotaSeverity
    let isCondensed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: isCondensed ? 9 : 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(severity.color)
            .padding(.horizontal, isCondensed ? 3 : 6)
            .frame(height: isCondensed ? 16 : 20)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .shadow(color: severity.glowColor, radius: severity.glowRadius * 0.6)
    }
}

private struct HUDWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.045, green: 0.047, blue: 0.052)
            } else {
                Color(red: 0.955, green: 0.96, blue: 0.97)
            }
            RadialGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.055 : 0.72),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.blue.opacity(0.025), Color.black.opacity(0.12)]
                    : [Color.blue.opacity(0.035), Color.black.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct HUDUnavailableView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 5)
                Image(systemName: symbol)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
            .frame(width: 72, height: 72)

            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.9))
            Text(message)
                .font(.caption2)
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI limits. \(title). \(message)")
    }
}

private enum WidgetQuotaSeverity {
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
        self == .critical ? .red.opacity(0.7) : color.opacity(0.24)
    }

    var glowRadius: CGFloat {
        self == .critical ? 7 : 2
    }
}

private extension CodexSessionPhase {
    var showsLight: Bool {
        self != .idle
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .complete: "Complete"
        case .needsInput: "Needs input"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: .clear
        case .thinking: Color(red: 0.18, green: 0.52, blue: 1.00)
        case .complete: Color(red: 0.18, green: 0.88, blue: 0.45)
        case .needsInput: Color(red: 1.00, green: 0.68, blue: 0.12)
        case .error: Color(red: 1.00, green: 0.20, blue: 0.47)
        }
    }
}

private struct WidgetToolMark: View {
    let snapshot: QuotaSnapshot
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if WidgetToolSymbol.isChatGPT(snapshot) {
                Image("ChatGPTMark")
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: WidgetToolSymbol.forSnapshot(snapshot))
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color.primary.opacity(0.88))
        .shadow(
            color: colorScheme == .dark ? .black.opacity(0.65) : .white.opacity(0.8),
            radius: colorScheme == .dark ? 3 : 1,
            y: 1
        )
        .accessibilityHidden(true)
    }
}

private enum WidgetToolSymbol {
    static func isChatGPT(_ snapshot: QuotaSnapshot) -> Bool {
        let value = "\(snapshot.toolName) \(snapshot.displayName)".lowercased()
        return value.contains("chatgpt") || value.contains("codex")
    }

    static func forSnapshot(_ snapshot: QuotaSnapshot) -> String {
        let value = "\(snapshot.toolName) \(snapshot.displayName)".lowercased()
        if value.contains("claude") { return "brain.head.profile" }
        if value.contains("gemini") { return "diamond.fill" }
        if value.contains("cursor") { return "cursorarrow.rays" }
        return "cpu"
    }
}

private enum WidgetQuotaFormat {
    static func arcFraction(_ remainingPercent: Double) -> Double {
        if remainingPercent <= 0 { return 1 }
        return min(max(remainingPercent / 100, 0), 1)
    }

    static func percent(_ remainingPercent: Double) -> String {
        "\(Int(min(max(remainingPercent, 0), 100).rounded()))%"
    }

    static func resetTag(resetAt: Date?, fallback: String, now: Date) -> String {
        guard let resetAt else { return fallback }
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0 else { return "NOW" }
        if remaining >= 86_400 {
            return "\(Int(ceil(remaining / 86_400)))D"
        }
        if remaining >= 3_600 {
            return "\(Int(ceil(remaining / 3_600)))H"
        }
        return "\(max(1, Int(ceil(remaining / 60))))M"
    }
}

private enum WidgetQuotaAccessibility {
    static func snapshot(_ snapshot: QuotaSnapshot) -> String {
        var parts = [
            snapshot.toolName,
            snapshot.displayName,
            window(
                typeTag: snapshot.typeTag,
                remainingPercent: snapshot.remainingPercent,
                resetAt: snapshot.resetAt
            )
        ]

        if let secondary = snapshot.secondaryWindow {
            parts.append(
                window(
                    typeTag: secondary.typeTag,
                    remainingPercent: secondary.remainingPercent,
                    resetAt: secondary.resetAt
                )
            )
        }

        if let planType = snapshot.planType, !planType.isEmpty {
            parts.append("\(planType) plan")
        }
        if let sessionStatus = snapshot.sessionStatus,
           sessionStatus.phase.showsLight {
            parts.append("Codex session \(sessionStatus.phase.label)")
        }
        return parts.joined(separator: ", ")
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func window(
        typeTag: String,
        remainingPercent: Double,
        resetAt: Date?
    ) -> String {
        var text = "\(typeTag) limit, \(WidgetQuotaFormat.percent(remainingPercent)) remaining"
        if let resetAt {
            text += ", resets \(date(resetAt))"
        } else {
            text += ", reset time unavailable"
        }
        return text
    }
}
