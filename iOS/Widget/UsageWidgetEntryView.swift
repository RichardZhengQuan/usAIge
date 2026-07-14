import SwiftUI
import UIKit
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
                WidgetUnavailableView(
                    symbol: "plus.circle",
                    title: "No limits yet",
                    message: "Open usAIge to add an AI tool."
                )
            case .error:
                WidgetUnavailableView(
                    symbol: "exclamationmark.triangle",
                    title: "Limits unavailable",
                    message: "Open usAIge to try again."
                )
            }
        }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    @ViewBuilder
    private func quotaContent(
        _ snapshots: [QuotaSnapshot],
        status: WidgetQuotaStatus
    ) -> some View {
        switch family {
        case .systemSmall:
            SmallQuotaWidget(snapshot: snapshots[0], status: status)
        case .systemLarge:
            QuotaListWidget(
                snapshots: Array(snapshots.prefix(4)),
                totalCount: snapshots.count,
                status: status,
                showsDetails: true
            )
        default:
            QuotaListWidget(
                snapshots: Array(snapshots.prefix(2)),
                totalCount: snapshots.count,
                status: status,
                showsDetails: false
            )
        }
    }
}

private enum WidgetQuotaStatus {
    case current
    case stale(Date)

    var title: String {
        switch self {
        case .current: "Current"
        case .stale: "Stale"
        }
    }

    var symbol: String {
        switch self {
        case .current: "checkmark.circle.fill"
        case .stale: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .current: .green
        case .stale: .orange
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .current:
            "Current cached data"
        case let .stale(date):
            "Stale cached data, oldest update \(WidgetQuotaAccessibility.date(date))"
        }
    }

    var staleDate: Date? {
        guard case let .stale(date) = self else { return nil }
        return date
    }
}

private struct WidgetHeader: View {
    let status: WidgetQuotaStatus
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Label("AI Limits", systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let count {
                Text(count, format: .number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) limits")
            }

            VStack(alignment: .trailing, spacing: 0) {
                Label(status.title, systemImage: status.symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(status.color)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                if let staleDate = status.staleDate {
                    Text(staleDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI limits, \(status.accessibilityDescription)")
    }
}

private struct SmallQuotaWidget: View {
    let snapshot: QuotaSnapshot
    let status: WidgetQuotaStatus

    private var displayedWindow: QuotaWindowSnapshot {
        guard let secondary = snapshot.secondaryWindow,
              secondary.remainingPercent < snapshot.remainingPercent else {
            return snapshot.primaryWindow
        }
        return secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetHeader(status: status)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.toolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(snapshot.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(WidgetQuotaFormat.percent(displayedWindow.remainingPercent))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(WidgetQuotaFormat.color(displayedWindow.remainingPercent))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.75)
                Text("remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(
                value: WidgetQuotaFormat.fraction(displayedWindow.remainingPercent),
                total: 1
            )
            .tint(WidgetQuotaFormat.color(displayedWindow.remainingPercent))
            .widgetAccentable()
            .accessibilityHidden(true)

            HStack(spacing: 4) {
                Text(displayedWindow.typeTag)
                    .fontWeight(.semibold)
                if let resetAt = displayedWindow.resetAt {
                    Text("·")
                    Text(resetAt, style: .relative)
                } else {
                    Text("· Reset unavailable")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(WidgetQuotaAccessibility.snapshot(snapshot)), \(status.accessibilityDescription)"
        )
    }
}

private struct QuotaListWidget: View {
    let snapshots: [QuotaSnapshot]
    let totalCount: Int
    let status: WidgetQuotaStatus
    let showsDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(status: status, count: totalCount)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(snapshots) { snapshot in
                    QuotaWidgetRow(snapshot: snapshot, showsDetails: showsDetails)
                        .padding(.vertical, showsDetails ? 5 : 3)
                    if snapshot.id != snapshots.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.top, showsDetails ? 5 : 3)

            if totalCount > snapshots.count {
                Text("+ \(totalCount - snapshots.count) more in usAIge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("\(totalCount - snapshots.count) more limits in usAIge")
                    .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .privacySensitive()
    }
}

private struct QuotaWidgetRow: View {
    let snapshot: QuotaSnapshot
    let showsDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetails ? 6 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.toolName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(snapshot.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                WindowValue(
                    typeTag: snapshot.typeTag,
                    remainingPercent: snapshot.remainingPercent
                )

                if let secondary = snapshot.secondaryWindow {
                    WindowValue(
                        typeTag: secondary.typeTag,
                        remainingPercent: secondary.remainingPercent
                    )
                }
            }

            ProgressView(
                value: WidgetQuotaFormat.fraction(snapshot.remainingPercent),
                total: 1
            )
            .tint(WidgetQuotaFormat.color(snapshot.remainingPercent))
            .widgetAccentable()
            .accessibilityHidden(true)

            if showsDetails {
                HStack(spacing: 4) {
                    if let resetAt = snapshot.resetAt {
                        Text("Resets")
                        Text(resetAt, style: .relative)
                    } else {
                        Text("Reset time unavailable")
                    }

                    if let planType = snapshot.planType, !planType.isEmpty {
                        Text("·")
                        Text(planType.capitalized)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetQuotaAccessibility.snapshot(snapshot))
    }
}

private struct WindowValue: View {
    let typeTag: String
    let remainingPercent: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(WidgetQuotaFormat.percent(remainingPercent))
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(WidgetQuotaFormat.color(remainingPercent))
                .contentTransition(.numericText())
            Text(typeTag)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct WidgetUnavailableView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI Limits", systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption.weight(.semibold))

            Spacer(minLength: 0)

            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI limits. \(title). \(message)")
    }
}

private enum WidgetQuotaFormat {
    static func fraction(_ remainingPercent: Double) -> Double {
        min(max(remainingPercent / 100, 0), 1)
    }

    static func percent(_ remainingPercent: Double) -> String {
        "\(Int(min(max(remainingPercent, 0), 100).rounded()))%"
    }

    static func color(_ remainingPercent: Double) -> Color {
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 20 { return .orange }
        return .accentColor
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
