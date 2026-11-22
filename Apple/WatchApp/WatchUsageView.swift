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
        let updatedAt = tools.map { $0.serverUpdatedAt ?? $0.sourceUpdatedAt }.max()

        return TimelineView(.everyMinute) { context in
            List {
                if model.errorMessage != nil || model.isStale {
                    statusBanner
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.tools) { tool in
                            if let limit = tool.tightestLimit {
                                WatchQuotaRow(
                                    tool: tool,
                                    limit: limit,
                                    isStale: model.isStale(tool),
                                    now: context.date
                                )
                            }
                        }
                    } header: {
                        if groups.count > 1 {
                            Text(group.title)
                        }
                    } footer: {
                        if group.id == groups.last?.id, let updatedAt {
                            Text("Updated \(updatedAt, style: .relative)")
                        }
                    }
                }
            }
            .refreshable { model.refresh() }
        }
    }

    private var statusBanner: some View {
        let message = model.errorMessage == nil ? "Some limits may be out of date" : "Showing saved limits"
        return Label(message, systemImage: "clock")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.errorMessage ?? message)
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

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                    .font(.headline)
                    .lineLimit(1)

                remainingAndReset

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilitySummary)
    }

    private var remainingAndReset: some View {
        let window = limit.tightestWindow
        let percent = Text(ModernUsageColor.percent(window.remainingPercent))
            .font(.title3.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(ModernUsageColor.color(remainingPercent: window.remainingPercent))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                percent
                resetCaption
            }
            VStack(alignment: .leading, spacing: 1) {
                percent
                resetCaption
            }
        }
    }

    @ViewBuilder
    private var resetCaption: some View {
        if let reset = ResetCountdown.phrase(until: limit.tightestWindow.resetAt, now: now) {
            Text(reset)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var accessibilityTitle: String {
        var title = "\(tool.displayName), \(limit.displayName)"
        if tool.otherLimitCount > 0 { title += ", \(tool.otherLimitCount) more" }
        return title
    }

    private var accessibilitySummary: String {
        var summary = limit.tightestWindow.accessibilitySummary(now: now)
        if isStale { summary += ", showing saved limits" }
        return summary
    }
}
