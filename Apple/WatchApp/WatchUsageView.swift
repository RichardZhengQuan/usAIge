import SwiftUI

struct WatchUsageView: View {
    @ObservedObject var model: WatchUsageModel

    private let brandGreen = Color(red: 0.70, green: 1, blue: 0.20)

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

    @ViewBuilder
    private func usageList(_ envelope: WatchUsageSnapshotEnvelope) -> some View {
        let groups = sourceGroups(in: envelope)

        let list = List {
            if model.errorMessage != nil || model.isStale {
                statusBanner
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.tools) { tool in
                        if group.tools.count > 1 {
                            Label(tool.displayName, systemImage: tool.symbolName ?? "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        ForEach(tool.limits) { limit in
                            WatchQuotaRow(
                                tool: tool,
                                limit: limit,
                                isStale: model.isStale(tool)
                            )
                        }
                    }
                } header: {
                    Label(group.title, systemImage: group.symbolName)
                } footer: {
                    if let updatedAt = group.updatedAt {
                        Text("Updated \(updatedAt, style: .relative)")
                    }
                }
            }
        }
        .refreshable { model.refresh() }
        list
    }

    private var statusBanner: some View {
        Label {
            Text(model.errorMessage == nil ? "Some limits may be out of date" : "Showing saved limits")
                .lineLimit(2)
        } icon: {
            Image(
                systemName: model.errorMessage == nil
                    ? "clock.badge.exclamationmark"
                    : "wifi.slash"
            )
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityLabel(
            model.errorMessage
                ?? "Some limits may be out of date. Showing the latest saved limits."
        )
    }

    private var loadingView: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                ConcentricQuotaRing(
                    primaryRemaining: 72,
                    secondaryRemaining: 88,
                    size: 60
                ) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                }

                ProgressView()
                    .tint(.primary)
                    .scaleEffect(0.62)
                    .frame(width: 19, height: 19)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 2, y: 2)
            }

            Text("SYNC")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(brandGreen)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Text(model.phoneIsReachable ? "Syncing from iPhone" : "Syncing from usAIge")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Getting the latest AI limits.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var emptyView: some View {
        ScrollView {
            VStack(spacing: 7) {
                ConcentricQuotaRing(
                    primaryRemaining: 0,
                    size: 64
                ) {
                    Image(
                        systemName: model.canRefresh
                            ? "iphone.and.arrow.forward"
                            : "iphone.slash"
                    )
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.canRefresh ? brandGreen : Color.secondary)
                    .offset(x: 1)
                }

                Text("SET UP")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(model.canRefresh ? brandGreen : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                Text(model.canRefresh ? "Limits Unavailable" : "iPhone Unavailable")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(
                    model.errorMessage
                        ?? (model.canRefresh
                            ? "Connect a Mac, then sync with usAIge."
                            : "Open usAIge on your paired iPhone.")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

                Button(model.canRefresh ? "Sync Now" : "Try Again") {
                    model.refresh()
                }
                .buttonStyle(.borderedProminent)
                .tint(brandGreen)
                .foregroundStyle(.black)
                .controlSize(.small)
                .disabled(!model.canRefresh)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    private func sourceGroups(in envelope: WatchUsageSnapshotEnvelope) -> [WatchSourceGroup] {
        let tools = envelope.tools.filter { !$0.limits.isEmpty }
        var order: [String] = []
        for tool in tools {
            let key = tool.sourceID ?? "legacy"
            if !order.contains(key) { order.append(key) }
        }

        return order.compactMap { key in
            let groupedTools = tools.filter { ($0.sourceID ?? "legacy") == key }
            guard let first = groupedTools.first else { return nil }
            return WatchSourceGroup(
                id: key,
                title: first.sourceName
                    ?? (groupedTools.count == 1 ? first.displayName : "AI Tools"),
                symbolName: first.sourceName == nil ? "sparkles" : "laptopcomputer",
                updatedAt: groupedTools.compactMap(\.serverUpdatedAt).max(),
                tools: groupedTools
            )
        }
    }
}

private struct WatchSourceGroup: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let updatedAt: Date?
    let tools: [WatchToolQuotaSnapshot]
}

private struct WatchQuotaRow: View {
    let tool: WatchToolQuotaSnapshot
    let limit: WatchQuotaSnapshot
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(limit.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 4)

                Text("\(Int(limit.effectiveRemainingPercent.rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(constrainingColor)
                    .lineLimit(1)
            }

            if !isStale,
               let status = tool.sessionStatus,
               status.phase.showsLight {
                WatchSessionStatusBadge(status: status)
            }

            Gauge(value: limit.constrainingWindow.remainingPercent, in: 0...100) {
                Text("Remaining")
            }
            .tint(constrainingColor)

            HStack(spacing: 5) {
                QuotaDurationTags(limit: limit)
                Spacer(minLength: 4)
                if isStale {
                    Label("Saved", systemImage: "clock")
                } else if let resetAt = limit.constrainingWindow.resetAt {
                    Text("Resets \(resetAt, style: .relative)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } else {
                    Text("Reset unavailable")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var constrainingColor: Color {
        switch limit.constrainingWindowRole {
        case .primary:
            UsagePalette.primary(remainingPercent: limit.constrainingWindow.remainingPercent)
        case .secondary:
            UsagePalette.secondary(remainingPercent: limit.constrainingWindow.remainingPercent)
        }
    }

    private var accessibilitySummary: String {
        var value = "\(tool.displayName), \(limit.displayName), \(windowSummary(limit.primary, fallback: "primary limit"))"
        if let secondary = limit.secondary {
            value += ", \(windowSummary(secondary, fallback: "secondary limit"))"
        }
        if !isStale,
           let status = tool.sessionStatus,
           status.phase.showsLight {
            value += ", Codex session \(status.phase.label)"
        }
        if isStale { value += ", showing saved data" }
        return value
    }

    private func windowSummary(_ window: WatchQuotaWindowSnapshot, fallback: String) -> String {
        let duration = window.durationDescription ?? fallback
        return "\(duration), \(Int(window.remainingPercent.rounded())) percent remaining"
    }
}

private struct QuotaDurationTags: View {
    let limit: WatchQuotaSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                QuotaWindowTag(window: limit.primary, role: .primary)
                if let secondary = limit.secondary {
                    QuotaWindowTag(window: secondary, role: .secondary)
                }
            }

            QuotaWindowTag(
                window: limit.constrainingWindow,
                role: limit.constrainingWindowRole
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
