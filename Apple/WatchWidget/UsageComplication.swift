import Foundation
import SwiftUI
import WidgetKit

struct UsageTimelineEntry: TimelineEntry {
    let date: Date
    let envelope: WatchUsageSnapshotEnvelope?

    var selectedLimit: SelectedLimit? {
        envelope?.tools
            .flatMap { tool in
                tool.limits.map { limit in
                    SelectedLimit(tool: tool, limit: limit)
                }
            }
            .min { lhs, rhs in
                if lhs.remainingPercent == rhs.remainingPercent {
                    return lhs.stableID < rhs.stableID
                }
                return lhs.remainingPercent < rhs.remainingPercent
            }
    }

    var selectedLimitIsStale: Bool {
        selectedLimit?.tool.isStale(at: date) ?? false
    }

    /// When the selected limit's data turns stale, if that is still ahead.
    var selectedLimitStaleDate: Date? {
        guard let selectedLimit else { return nil }
        let staleDate = selectedLimit.tool.staleAfter.addingTimeInterval(1)
        return staleDate > date ? staleDate : nil
    }
}

struct SelectedLimit {
    let tool: WatchToolQuotaSnapshot
    let limit: WatchQuotaSnapshot

    var stableID: String {
        "\(tool.id):\(limit.id)"
    }

    var remainingPercent: Double {
        limit.tightestWindow.remainingPercent
    }

    var resetAt: Date? {
        limit.tightestWindow.resetAt
    }

    var percent: String {
        ModernUsageColor.percent(remainingPercent)
    }

    var color: Color {
        ModernUsageColor.color(remainingPercent: remainingPercent)
    }
}

struct UsageTimelineProvider: TimelineProvider {
    private let cache = WatchSnapshotFileStore(fileURL: AppGroup.snapshotURL())

    func placeholder(in context: Context) -> UsageTimelineEntry {
        UsageTimelineEntry(date: Date(), envelope: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageTimelineEntry) -> Void) {
        let cachedEnvelope = try? cache.load()
        let envelope = cachedEnvelope ?? (context.isPreview ? .preview : nil)
        completion(UsageTimelineEntry(date: Date(), envelope: envelope))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageTimelineEntry>) -> Void) {
        let now = Date()
        let envelope = try? cache.load()
        let entry = UsageTimelineEntry(date: now, envelope: envelope)
        let scheduled = now.addingTimeInterval(envelope == nil ? 5 * 60 : 15 * 60)
        let resetRefresh = entry.selectedLimit?.resetAt
            .flatMap { $0 > now ? $0.addingTimeInterval(2) : nil }
        let refreshAt = min(scheduled, resetRefresh ?? scheduled)
        var entries = [entry]
        // If watchOS delays the next refresh, this prebuilt entry still
        // marks the cached numbers stale once they are.
        if let staleDate = entry.selectedLimitStaleDate {
            entries.append(UsageTimelineEntry(date: staleDate, envelope: envelope))
        }
        completion(Timeline(entries: entries, policy: .after(refreshAt)))
    }
}

struct UsageComplicationView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: UsageTimelineEntry
    private let familyOverride: WidgetFamily?

    init(entry: UsageTimelineEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        familyOverride = family
    }

    var body: some View {
        let selected = entry.selectedLimit
        let phase = selected?.tool.visibleSessionPhase(isStale: entry.selectedLimitIsStale)

        Group {
            switch familyOverride ?? widgetFamily {
            case .accessoryCircular:
                circular(selected)
            case .accessoryCorner:
                corner(selected)
            case .accessoryInline:
                inline(selected)
            default:
                rectangular(selected, phase: phase)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: selected, phase: phase))
    }

    @ViewBuilder
    private func circular(_ selected: SelectedLimit?) -> some View {
        if let selected {
            GeometryReader { geometry in
                quotaRing(selected, size: min(geometry.size.width, geometry.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            emptySymbol
        }
    }

    @ViewBuilder
    private func rectangular(_ selected: SelectedLimit?, phase: WatchSessionPhase?) -> some View {
        if let selected {
            HStack(spacing: 7) {
                quotaRing(selected, size: 40)

                let summary = rectangularSummary(selected, phase: phase)
                ViewThatFits {
                    if selected.tool.otherLimitCount > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            summary
                            Text("\(selected.limit.displayName) · +\(selected.tool.otherLimitCount) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    summary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 7) {
                emptySymbol
                Text("Open usAIge on iPhone")
                    .font(.caption)
            }
        }
    }

    private func rectangularSummary(_ selected: SelectedLimit, phase: WatchSessionPhase?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            WatchToolTitle(name: selected.tool.displayName, phase: phase)
                .font(.caption.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(selected.percent)
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(selected.color)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let reset = ResetCountdown.phrase(until: selected.resetAt, now: entry.date) {
                    Text(reset)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    @ViewBuilder
    private func inline(_ selected: SelectedLimit?) -> some View {
        if let selected {
            let countdown = ResetCountdown.compact(until: selected.resetAt, now: entry.date)
            Text("\(selected.tool.displayName) \(selected.percent) · \(countdown)")
                .lineLimit(1)
        } else {
            Text("Open usAIge on iPhone")
        }
    }

    @ViewBuilder
    private func corner(_ selected: SelectedLimit?) -> some View {
        if let selected {
            let mark = ToolMark(toolName: selected.tool.displayName, symbolName: selected.tool.symbolName)
                .frame(width: 24, height: 24)
                .foregroundStyle(.primary)
                .widgetAccentable()
                .opacity(entry.selectedLimitIsStale ? 0.55 : 1)
            let gauge = Gauge(value: selected.remainingPercent, in: 0...100) {
                Text("Percent left")
            } currentValueLabel: {
                Text(selected.percent)
            }
            .tint(selected.color)

            if familyOverride != nil {
                // WidgetKit draws the widget label on the watch face.
                VStack(spacing: 2) {
                    mark
                    gauge.gaugeStyle(.accessoryLinearCapacity)
                }
            } else {
                mark.widgetLabel { gauge }
            }
        } else {
            emptySymbol
        }
    }

    private func quotaRing(_ selected: SelectedLimit, size: CGFloat) -> some View {
        ModernQuotaRing(
            primary: selected.limit.primary.remainingPercent,
            secondary: selected.limit.secondary?.remainingPercent,
            size: size,
            isDimmed: entry.selectedLimitIsStale
        ) {
            ToolMark(toolName: selected.tool.displayName, symbolName: selected.tool.symbolName)
                .foregroundStyle(.primary)
        }
        .widgetAccentable()
    }

    private var emptySymbol: some View {
        Image(systemName: "iphone.and.arrow.forward")
            .font(.title3)
            .widgetAccentable()
    }

    private func accessibilityText(for selected: SelectedLimit?, phase: WatchSessionPhase?) -> String {
        guard let selected else { return "Open usAIge on iPhone" }
        let summary = selected.limit.tightestWindow.accessibilitySummary(now: entry.date)
        var text = selected.tool.displayName
        if let phase { text += ", \(phase.label.lowercased())" }
        text += ", \(selected.limit.displayName), \(summary)"
        if let sourceName = selected.tool.sourceName { text += ", \(sourceName)" }
        if entry.selectedLimitIsStale { text += ", data may be stale" }
        return text
    }
}

struct UsageComplication: Widget {
    let kind = AppGroup.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            UsageComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI limits")
        .description("See the AI quota with the least allowance remaining.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

private extension WatchUsageSnapshotEnvelope {
    static var preview: WatchUsageSnapshotEnvelope {
        let now = Date()
        return WatchUsageSnapshotEnvelope(
            generatedAt: now,
            tools: [
                    WatchToolQuotaSnapshot(
                        id: "preview",
                        displayName: "Claude Team",
                        sourceID: "preview-mac",
                        sourceName: "Richard's Mac",
                        serverUpdatedAt: now,
                        sourceUpdatedAt: now,
                    receivedAt: now,
                    limits: [
                        WatchQuotaSnapshot(
                            id: "messages",
                            displayName: "Messages",
                            primary: WatchQuotaWindowSnapshot(
                                remainingPercent: 42,
                                resetAt: now.addingTimeInterval(90 * 60),
                                windowDurationSeconds: 5 * 60 * 60
                            ),
                            secondary: WatchQuotaWindowSnapshot(
                                remainingPercent: 19,
                                resetAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                                windowDurationSeconds: 7 * 24 * 60 * 60
                            ),
                            planType: "team"
                        ),
                    ],
                    sessionStatus: WatchSessionStatus(phase: .thinking, updatedAt: now),
                    symbolName: "brain.head.profile"
                ),
            ]
        )
    }
}
