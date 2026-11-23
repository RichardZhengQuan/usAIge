import Foundation
import SwiftUI

struct WatchUsageView: View {
    @ObservedObject var model: WatchUsageModel

    var body: some View {
        NavigationStack {
            Group {
                if let envelope = model.envelope,
                   envelope.tools.contains(where: { !$0.limits.isEmpty }) {
                    usageList(envelope)
                } else if model.isRefreshing {
                    loadingView
                } else {
                    emptyView
                }
            }
            .navigationTitle("usAIge")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear(perform: model.refreshIfNeeded)
    }

    private func usageList(_ envelope: WatchUsageSnapshotEnvelope) -> some View {
        let tools = envelope.tools.filter { !$0.limits.isEmpty }
        let groups = sourceGroups(in: tools)

        return TimelineView(.everyMinute) { context in
            List {
                if let message = model.errorMessage {
                    Label(message, systemImage: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(message)
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.tools) { tool in
                            if let limit = tool.tightestLimit {
                                WatchQuotaRow(
                                    tool: tool,
                                    limit: limit,
                                    isStale: tool.isStale(at: context.date),
                                    now: context.date
                                )
                            }
                        }
                    } header: {
                        if groups.count > 1 {
                            Text(group.title)
                        }
                    } footer: {
                        sourceFooter(for: group, now: context.date)
                    }
                }
            }
            .refreshable { model.refresh() }
        }
    }

    @ViewBuilder
    private func sourceFooter(for group: WatchSourceGroup, now: Date) -> some View {
        if let updatedAt = group.tools.map(\.sourceUpdatedAt).max() {
            let age = updatedAt.formatted(.relative(presentation: .named))
            HStack(spacing: 4) {
                if group.tools.contains(where: { $0.isStale(at: now) }) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                }
                Text("Updated \(age)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        syncMessage(
            symbol: "iphone.and.arrow.forward",
            title: model.phoneIsReachable ? "Syncing from iPhone" : "Syncing from usAIge",
            detail: "Getting the latest AI limits."
        )
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ScrollView {
            VStack(spacing: 8) {
                syncMessage(
                    symbol: model.canRefresh ? "iphone.and.arrow.forward" : "iphone.slash",
                    title: model.canRefresh ? "Limits Unavailable" : "iPhone Unavailable",
                    detail: model.errorMessage ?? (model.canRefresh
                        ? "Connect a Mac, then sync."
                        : "Open usAIge on your paired iPhone.")
                )

                Button(model.canRefresh ? "Sync Now" : "Try Again", action: model.refresh)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.canRefresh)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private func syncMessage(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private func sourceGroups(in tools: [WatchToolQuotaSnapshot]) -> [WatchSourceGroup] {
        let grouped = Dictionary(grouping: tools, by: \.sourceID)
        var seen = Set<String?>()
        return tools.compactMap { tool in
            guard seen.insert(tool.sourceID).inserted, let sourceTools = grouped[tool.sourceID] else { return nil }
            return WatchSourceGroup(id: tool.sourceID, tools: sourceTools)
        }
    }
}

private struct WatchSourceGroup: Identifiable {
    let id: String?
    let tools: [WatchToolQuotaSnapshot]

    var title: String {
        tools.compactMap(\.sourceName).first ?? "Mac"
    }
}

private struct WatchQuotaRow: View {
    let tool: WatchToolQuotaSnapshot
    let limit: WatchQuotaSnapshot
    let isStale: Bool
    let now: Date

    var body: some View {
        let phase = tool.visibleSessionPhase(isStale: isStale)

        HStack(spacing: 8) {
            ModernQuotaRing(
                primary: limit.primary.remainingPercent,
                secondary: limit.secondary?.remainingPercent,
                size: 46,
                isDimmed: isStale
            ) {
                ToolMark(toolName: tool.displayName, symbolName: tool.symbolName)
                    .foregroundStyle(.primary)
            }

            // The reset badge sits at the end of the title line, as on the
            // iPhone. On a small watch where the name and badge don't both
            // fit, it moves to the caption line so the name stays whole.
            ViewThatFits(in: .horizontal) {
                details(phase: phase, badgeOnTitleLine: true)
                details(phase: phase, badgeOnTitleLine: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle(phase: phase))
        .accessibilityValue(accessibilitySummary)
    }

    private func details(phase: WatchSessionPhase?, badgeOnTitleLine: Bool) -> some View {
        let hasBadge = (tool.availableResetCount ?? 0) > 0
        return VStack(alignment: .leading, spacing: 2) {
            if badgeOnTitleLine {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    WatchToolTitle(name: tool.displayName, phase: phase)
                        .font(.headline)
                    Spacer(minLength: 0)
                    ResetCreditBadge(count: tool.availableResetCount)
                }
                .fixedSize(horizontal: true, vertical: false)
            } else {
                WatchToolTitle(name: tool.displayName, phase: phase)
                    .font(.headline)
            }

            remainingAndReset

            if tool.otherLimitCount > 0 || (hasBadge && !badgeOnTitleLine) {
                HStack(spacing: 4) {
                    if tool.otherLimitCount > 0 {
                        ViewThatFits(in: .horizontal) {
                            Text("\(limit.displayName) · +\(tool.otherLimitCount) more")
                                .fixedSize(horizontal: true, vertical: false)
                            Text("+\(tool.otherLimitCount) more")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    if !badgeOnTitleLine {
                        ResetCreditBadge(count: tool.availableResetCount)
                    }
                }
            }
        }
    }

    private var remainingAndReset: some View {
        let window = limit.tightestWindow
        let percent = Text(ModernUsageColor.percent(window.remainingPercent))
            .font(.title3.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(ModernUsageColor.color(remainingPercent: window.remainingPercent))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

        // "62% resets 2H", then "62% 2H" on small watches, and only then two lines.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                percent
                resetText(ResetCountdown.phrase(until: window.resetAt, now: now))
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                percent
                resetText(window.resetAt == nil ? nil : ResetCountdown.compact(until: window.resetAt, now: now))
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 1) {
                percent
                resetText(ResetCountdown.phrase(until: window.resetAt, now: now))
            }
        }
    }

    @ViewBuilder
    private func resetText(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func accessibilityTitle(phase: WatchSessionPhase?) -> String {
        var title = tool.displayName
        if let phase { title += ", \(phase.label.lowercased())" }
        title += ", \(limit.displayName)"
        if tool.otherLimitCount > 0 { title += ", \(tool.otherLimitCount) more" }
        return title
    }

    private var accessibilitySummary: String {
        var summary = limit.tightestWindow.accessibilitySummary(now: now)
        if let credit = ResetCreditText.accessibilityLabel(count: tool.availableResetCount) {
            summary += ", \(credit)"
        }
        if isStale { summary += ", showing saved limits" }
        return summary
    }
}
