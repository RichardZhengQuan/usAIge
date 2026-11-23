import Foundation
import SwiftUI

struct QuotaRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let tool: ToolUsageSummary
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let session = tool.activeSession
        VStack(alignment: .leading, spacing: 8) {
            disclosureButton(phase: session?.phase)
            if isExpanded {
                expandedContent(session: session)
            }
        }
        .padding(.vertical, 4)
    }

    private func disclosureButton(phase: CodexSessionPhase?) -> some View {
        TimelineView(.everyMinute) { context in
            Button(action: toggle) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        header(phase: phase)
                        if !isExpanded {
                            quotaBars(for: tool.tightest)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle(phase: phase, now: context.date))
            .accessibilityValue(isExpanded ? Text("expanded") : Text("collapsed"))
            .accessibilityHint(Text("Shows every limit"))
        }
    }

    @ViewBuilder
    private func expandedContent(session: CodexSessionStatus?) -> some View {
        ForEach(tool.limits) { limit in
            VStack(alignment: .leading, spacing: 4) {
                limitTitle(limit)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    quotaBars(for: limit)
                }
            }
        }

        let resets = ResetCreditLine.lines(for: tool)
        if !resets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(resets) { resetRow($0) }
            }
        }

        if let session {
            sessionRow(session)
        }
    }

    @ViewBuilder
    private func quotaBars(for limit: QuotaSnapshot) -> some View {
        ModernQuotaBar(window: limit.primaryWindow)
        if let secondary = limit.secondaryWindow {
            ModernQuotaBar(window: secondary)
        }
    }

    private func limitTitle(_ limit: QuotaSnapshot) -> Text {
        let name = Text(limit.displayName)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
        if let plan = limit.planType, !plan.isEmpty {
            return Text("\(name) \(Text(plan).foregroundStyle(.tertiary))")
        }
        return name
    }

    private func resetRow(_ line: ResetCreditLine) -> some View {
        let title = Text(line.credit.title).fontWeight(.semibold)
        let metadata = resetMetadata(line)?.foregroundStyle(.secondary)

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let metadata {
                    Text("\(title) \(metadata)")
                } else {
                    title
                }
                if let detail = line.credit.detail, !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func resetMetadata(_ line: ResetCreditLine) -> Text? {
        let expiry = line.credit.expiresAt.map { Text("expires \($0, format: .dateTime.month(.abbreviated).day())") }
        guard let count = line.availableCount else { return expiry }
        let availability = Text("\(count) available")
        return expiry.map { Text("\(availability) · \($0)") } ?? availability
    }

    private func sessionRow(_ session: CodexSessionStatus) -> some View {
        let phase = Text(session.phase.label)
        let relativeTime = Text(.currentDate, format: .reference(to: session.updatedAt, maxFieldCount: 1))
            .foregroundStyle(.secondary)

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            UsageSessionDot(phase: session.phase)
            Text("\(phase) \(relativeTime)")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func header(phase: CodexSessionPhase?) -> some View {
        let title = HStack(spacing: 6) {
            Text(tool.name)
                .font(.headline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            if let phase {
                UsageSessionDot(phase: phase)
            }
        }

        return HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 8) {
            ToolMarkTile(
                kind: ToolMarkKind(toolName: tool.name, symbolName: tool.symbolName),
                fallbackSymbol: tool.symbolName
            )
            if !isExpanded, tool.otherLimitCount > 0 {
                let caption = limitCaption
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        caption
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 2) {
                        title
                        caption
                    }
                }
            } else {
                title
            }

            Spacer(minLength: 0)
            if let count = tool.availableResetCount, count > 0 {
                ResetCreditBadge(count: count)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
    }

    private var limitCaption: Text {
        Text("\(tool.tightest.displayName) · +\(tool.otherLimitCount) more")
    }

    private func accessibilityTitle(phase: CodexSessionPhase?, now: Date) -> Text {
        let name = Text(tool.name)
        var title = !isExpanded && tool.otherLimitCount > 0 ? Text("\(name), \(limitCaption)") : name
        if let phase {
            title = Text("\(title), \(phase.label)")
        }
        if let count = tool.availableResetCount, count > 0 {
            let credit = count == 1 ? Text("\(count) reset available") : Text("\(count) resets available")
            title = Text("\(title), \(credit)")
        }
        if !isExpanded {
            title = Text("\(title). \(accessibilityWindows(now: now))")
        }
        return title
    }

    private func accessibilityWindows(now: Date) -> String {
        let limit = tool.tightest
        let windows = [limit.primaryWindow, limit.secondaryWindow].compactMap { $0 }
        return windows.map { window in
            let label = window.displayedTag.map { String(localized: "\($0) window") } ?? String(localized: "Limit")
            let percent = ModernUsageColor.percent(window.remainingPercent)
            let reset = ResetCountdown.accessibilityLabel(until: window.resetAt, now: now)
            return String(localized: "\(label), \(percent) left, \(reset)")
        }.joined(separator: ". ")
    }
}

struct ResetCreditLine: Identifiable, Equatable {
    let credit: ResetCreditSnapshot
    let availableCount: Int?

    var id: String { credit.id }

    static func lines(for tool: ToolUsageSummary) -> [Self] {
        if !tool.resetCredits.isEmpty {
            return tool.resetCredits.map { Self(credit: $0, availableCount: nil) }
        }
        guard let count = tool.availableResetCount, count > 0 else { return [] }

        let fallback = ResetCreditSnapshot(
            id: "full-reset", title: String(localized: "Full reset"), expiresAt: tool.resetCreditExpiresAt
        )
        return [Self(credit: fallback, availableCount: count)]
    }
}

struct UsageSessionDot: View {
    let phase: CodexSessionPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch phase {
        case .idle: .clear
        case .thinking: .blue
        case .complete: .green
        case .needsInput: .orange
        case .error: .red
        }
    }
}

extension ToolUsageSummary {
    var activeSession: CodexSessionStatus? {
        let session = limits.lazy.compactMap(\.sessionStatus).max { $0.updatedAt < $1.updatedAt }
        guard let session, session.phase.showsLight else { return nil }
        return session
    }
}

extension ModernQuotaBar {
    init(window: QuotaWindowSnapshot) {
        self.init(tag: window.displayedTag, remainingPercent: window.remainingPercent, resetAt: window.resetAt)
    }
}

private extension QuotaWindowSnapshot {
    var displayedTag: String? {
        windowDurationMinutes == nil ? nil : typeTag
    }
}
