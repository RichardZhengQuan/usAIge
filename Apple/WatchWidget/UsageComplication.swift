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
        guard let selectedLimit else { return false }
        return date.timeIntervalSince(selectedLimit.tool.sourceUpdatedAt) > 30 * 60
    }
}

struct SelectedLimit {
    let tool: WatchToolQuotaSnapshot
    let limit: WatchQuotaSnapshot

    var stableID: String {
        "\(tool.id):\(limit.id)"
    }

    var scopeName: String {
        guard let sourceName = tool.sourceName else { return tool.displayName }
        return "\(sourceName) · \(tool.displayName)"
    }

    var remainingPercent: Double {
        constrainingWindow.remainingPercent
    }

    var constrainingWindow: WatchQuotaWindowSnapshot {
        limit.constrainingWindow
    }

    var constrainingRole: QuotaWindowTag.Role {
        limit.constrainingWindowRole
    }

    var resetAt: Date? {
        constrainingWindow.resetAt
    }

    var durationTag: String {
        constrainingWindow.compactDurationTag
            ?? (constrainingRole == .primary ? "LIMIT" : "MORE")
    }

    var color: Color {
        switch constrainingRole {
        case .primary:
            UsagePalette.primary(remainingPercent: remainingPercent)
        case .secondary:
            UsagePalette.secondary(remainingPercent: remainingPercent)
        }
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
        completion(Timeline(entries: [entry], policy: .after(refreshAt)))
    }
}

struct UsageComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageTimelineEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryCorner:
                corner
            case .accessoryInline:
                inline
            case .accessoryRectangular:
                rectangular
            default:
                rectangular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var circular: some View {
        if let selected = entry.selectedLimit {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                ZStack(alignment: .bottomTrailing) {
                    ConcentricQuotaRing(
                        primaryRemaining: selected.limit.primary.remainingPercent,
                        secondaryRemaining: selected.limit.secondary?.remainingPercent,
                        size: size,
                        isStale: entry.selectedLimitIsStale
                    ) {
                        Image(systemName: selected.tool.symbolName ?? "sparkles")
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.06)
                            .foregroundStyle(.primary)
                    }
                    .widgetAccentable()

                    if entry.selectedLimitIsStale {
                        Image(systemName: "clock.fill")
                            .font(.system(size: max(8, size * 0.17), weight: .semibold))
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Image(systemName: "hourglass.badge.plus")
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if let selected = entry.selectedLimit {
            HStack(spacing: 7) {
                ConcentricQuotaRing(
                    primaryRemaining: selected.limit.primary.remainingPercent,
                    secondaryRemaining: selected.limit.secondary?.remainingPercent,
                    size: 43,
                    isStale: entry.selectedLimitIsStale
                ) {
                    Image(systemName: selected.tool.symbolName ?? "sparkles")
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                        .foregroundStyle(.primary)
                }
                .widgetAccentable()

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(
                            systemName: selected.tool.sourceName == nil
                                ? (selected.tool.symbolName ?? "sparkles")
                                : "laptopcomputer"
                        )
                        .font(.caption2)
                        Text(selected.tool.sourceName ?? selected.tool.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }

                    Text(
                        selected.tool.sourceName == nil
                            ? selected.limit.displayName
                            : "\(selected.tool.displayName) · \(selected.limit.displayName)"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 3) {
                        QuotaWindowTag(
                            window: selected.constrainingWindow,
                            role: selected.constrainingRole,
                            includesPercentage: true
                        )
                        if entry.selectedLimitIsStale {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if let resetAt = selected.resetAt {
                            Text(resetAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title3)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set up usAIge")
                        .font(.headline)
                    Text("Open the iPhone app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let selected = entry.selectedLimit {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    inlineSummary(selected)
                    if !entry.selectedLimitIsStale, let resetAt = selected.resetAt {
                        Text("·")
                        Text(resetAt, style: .relative)
                    }
                }
                inlineSummary(selected)
            }
        } else {
            Label("usAIge — set up on iPhone", systemImage: "hourglass.badge.plus")
        }
    }

    private func inlineSummary(_ selected: SelectedLimit) -> some View {
        Label(
            "\(selected.scopeName) · \(selected.durationTag) \(Int(selected.remainingPercent.rounded()))%",
            systemImage: entry.selectedLimitIsStale
                ? "clock.badge.exclamationmark"
                : (selected.tool.symbolName ?? "hourglass")
        )
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder
    private var corner: some View {
        if let selected = entry.selectedLimit {
            usAIgeCurvedLabel
                .textCase(nil)
                .widgetCurvesContent()
                .widgetLabel {
                    ProgressView(
                        value: UsagePalette.arcFraction(
                            remainingPercent: selected.remainingPercent
                        )
                    )
                }
                .tint(entry.selectedLimitIsStale ? .orange : selected.color)
                .opacity(entry.selectedLimitIsStale ? 0.62 : 1)
        } else {
            usAIgeCurvedLabel
                .textCase(nil)
                .widgetCurvesContent()
                .widgetLabel {
                    Text("Set up")
                }
                .tint(.secondary)
        }
    }

    private var usAIgeCurvedLabel: Text {
        // WidgetKit forces ordinary Latin text to uppercase in corner curves.
        // These sans-serif lowercase glyphs preserve the usAIge wordmark casing.
        Text("𝗎𝗌").foregroundColor(.white)
            + Text("AI").foregroundColor(Color(red: 0.70, green: 1, blue: 0.20))
            + Text("𝗀𝖾").foregroundColor(.white)
    }

    private var accessibilityText: String {
        guard let selected = entry.selectedLimit else {
            return "No AI usage limits. Set up usAIge on iPhone."
        }
        var text = "\(selected.scopeName), \(selected.limit.displayName), \(selected.durationTag), \(Int(selected.remainingPercent.rounded())) percent remaining"
        if entry.selectedLimitIsStale { text += ", data may be stale" }
        return text
    }
}

struct UsageComplication: Widget {
    let kind = AppGroup.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            UsageComplicationView(entry: entry)
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
                    symbolName: "brain.head.profile"
                ),
            ]
        )
    }
}
