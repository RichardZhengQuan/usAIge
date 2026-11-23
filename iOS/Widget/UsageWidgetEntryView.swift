import Foundation
import SwiftUI
import WidgetKit

struct UsageWidgetEntryView: View {
    let entry: QuotaTimelineEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        Group {
            switch entry.state {
            case let .current(snapshots):
                quotaContent(snapshots, isStale: false)
            case let .stale(snapshots, _):
                quotaContent(snapshots, isStale: true)
            case .empty:
                noLimits
            case .error:
                WidgetUnavailableView(
                    symbol: "exclamationmark.circle",
                    title: "Unavailable",
                    message: "Open usAIge to refresh."
                )
                .padding(margins)
            }
        }
        .transaction { $0.animation = nil }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    @ViewBuilder
    private func quotaContent(_ snapshots: [QuotaSnapshot], isStale: Bool) -> some View {
        if let first = snapshots.first {
            Group {
                if isSmall {
                    ViewThatFits(in: .vertical) {
                        quotaColumn(for: first, ringSize: 88, isStale: isStale)
                        quotaColumn(for: first, ringSize: 76, isStale: isStale)
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(snapshots.prefix(4)) { snapshot in
                            quotaColumn(for: snapshot, ringSize: 64, isStale: isStale)
                                .frame(minWidth: 0, maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(contentMargins)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if isStale {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, min(margins.top, 10))
                        .padding(.trailing, margins.trailing)
                        .accessibilityHidden(true)
                }
            }
        } else {
            noLimits
        }
    }

    private var contentMargins: EdgeInsets {
        guard isSmall else { return margins }
        return EdgeInsets(
            top: min(margins.top, 8),
            leading: margins.leading,
            bottom: min(margins.bottom, 8),
            trailing: margins.trailing
        )
    }

    private func quotaColumn(for snapshot: QuotaSnapshot, ringSize: CGFloat, isStale: Bool) -> some View {
        WidgetQuotaColumn(
            snapshot: snapshot,
            now: entry.date,
            ringSize: ringSize,
            isSmall: isSmall,
            isStale: isStale
        )
    }

    private var noLimits: some View {
        WidgetUnavailableView(
            symbol: "plus.circle",
            title: "No limits",
            message: "Open usAIge to add an AI tool."
        )
        .padding(margins)
    }
}

private struct WidgetQuotaColumn: View {
    let snapshot: QuotaSnapshot
    let now: Date
    let ringSize: CGFloat
    let isSmall: Bool
    let isStale: Bool

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let window = tightestWindow
        let percent = ModernUsageColor.percent(window.remainingPercent)
        let phase = visibleSessionPhase

        VStack(spacing: 2) {
            quotaRing
                .overlay(alignment: .topTrailing) {
                    if let phase {
                        Circle()
                            .fill(renderingMode == .fullColor ? phase.dotColor : Color.primary)
                            .frame(width: 6, height: 6)
                            .padding(ringSize * 0.065)
                    }
                }

            Text(percent)
                .font((isSmall ? Font.title3 : .callout).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(
                    renderingMode == .fullColor
                        ? ModernUsageColor.color(remainingPercent: window.remainingPercent)
                        : Color.primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            resetLine(until: window.resetAt)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(snapshot.toolName), \(snapshot.displayName)"))
        .accessibilityValue(Text(accessibilityValue(percent: percent, resetAt: window.resetAt, phase: phase)))
    }

    @ViewBuilder
    private func resetLine(until resetAt: Date?) -> some View {
        let reset = ResetCountdown.phrase(until: resetAt, now: now)
        let caption = Text(reset ?? "")
            .font(isSmall ? .caption : .caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

        if let count = snapshot.availableResetCount, count > 0 {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if reset != nil { caption }
                    ResetCreditBadge(count: count)
                }
                .fixedSize(horizontal: true, vertical: false)

                if reset != nil {
                    caption
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        } else if reset != nil {
            caption
        }
    }

    private var tightestWindow: QuotaWindowSnapshot {
        if let secondary = snapshot.secondaryWindow, secondary.remainingPercent < snapshot.remainingPercent {
            return secondary
        }
        return snapshot.primaryWindow
    }

    private var visibleSessionPhase: CodexSessionPhase? {
        guard let phase = snapshot.sessionStatus?.phase, phase.showsLight else { return nil }
        return phase
    }

    private var toolMark: ToolMark {
        ToolMark(toolName: snapshot.toolName, symbolName: snapshot.toolSymbolName)
    }

    @ViewBuilder
    private var quotaRing: some View {
        if renderingMode == .fullColor {
            ModernQuotaRing(
                primary: snapshot.remainingPercent,
                secondary: snapshot.secondaryWindow?.remainingPercent,
                size: ringSize,
                isDimmed: isStale
            ) {
                toolMark
            }
            .foregroundStyle(.primary)
        } else {
            monochromeRing
        }
    }

    // WidgetKit accents a whole subtree. Draw the arcs separately so the tracks
    // and tool mark stay in its default group.
    private var monochromeRing: some View {
        typealias Ring = ModernQuotaRing<ToolMark>
        let lineWidth = Ring.outerLineWidth(size: ringSize)
        let diameter = ringSize - lineWidth
        let markSize = ringSize * Ring.markScale

        return ZStack {
            if let secondary = snapshot.secondaryWindow {
                monochromeWindow(remaining: secondary.remainingPercent, diameter: diameter, lineWidth: lineWidth * 0.9)
                monochromeWindow(remaining: snapshot.remainingPercent, diameter: diameter * Ring.innerScale, lineWidth: lineWidth)
            } else {
                monochromeWindow(remaining: snapshot.remainingPercent, diameter: diameter, lineWidth: lineWidth)
            }
            toolMark.frame(width: markSize, height: markSize)
        }
        .foregroundStyle(.primary)
        .frame(width: ringSize, height: ringSize)
        .opacity(isStale ? 0.55 : 1)
        .accessibilityHidden(true)
    }

    private func monochromeWindow(remaining: Double, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: ModernUsageColor.fillFraction(remainingPercent: remaining))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable(renderingMode == .accented)
        }
        .frame(width: diameter, height: diameter)
    }

    private func accessibilityValue(percent: String, resetAt: Date?, phase: CodexSessionPhase?) -> String {
        var value = "\(percent.dropLast()) percent left, \(ResetCountdown.accessibilityLabel(until: resetAt, now: now))"
        if let credit = ResetCreditText.accessibilityLabel(count: snapshot.availableResetCount) {
            value += ", \(credit)"
        }
        if let phase { value += ", \(phase.label.lowercased())" }
        if isStale { value += ", saved data" }
        return value
    }
}

private extension CodexSessionPhase {
    var dotColor: Color {
        switch self {
        case .idle: .clear
        case .thinking: .blue
        case .complete: .green
        case .needsInput: .orange
        case .error: .red
        }
    }
}

private struct WidgetUnavailableView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
