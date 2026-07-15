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
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func usageList(_ envelope: WatchUsageSnapshotEnvelope) -> some View {
        let tools = envelope.tools.filter { !$0.limits.isEmpty }

        return List {
            if model.errorMessage != nil || model.isStale {
                statusBanner
            }

            ForEach(tools) { tool in
                let isStale = model.isStale(tool)
                Section {
                    ForEach(tool.limits) { limit in
                        NavigationLink {
                            QuotaDetailView(tool: tool, limit: limit)
                        } label: {
                            WatchQuotaRow(tool: tool, limit: limit, isStale: isStale)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(
                            EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
                        )
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    ToolSectionHeader(
                        tool: tool,
                        isStale: isStale,
                        showsRefresh: tool.id == tools.first?.id,
                        isRefreshing: model.isRefreshing,
                        refreshStatusColor: toolbarStatusColor,
                        refreshStatusDescription: toolbarStatusDescription,
                        onRefresh: model.refresh
                    )
                }
            }
        }
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
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6))
        .listRowBackground(Color.clear)
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
                .foregroundStyle(.cyan)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Text("Syncing from iPhone")
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
                        systemName: model.phoneIsReachable
                            ? "iphone.and.arrow.forward"
                            : "iphone.slash"
                    )
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.phoneIsReachable ? Color.cyan : Color.secondary)
                }

                Text("SET UP")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(model.phoneIsReachable ? Color.cyan : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                Text(model.phoneIsReachable ? "No Limits Yet" : "iPhone Unavailable")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(
                    model.errorMessage
                        ?? (model.phoneIsReachable
                            ? "Add an AI tool in usAIge on iPhone."
                            : "Open usAIge on your paired iPhone.")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

                Button(model.phoneIsReachable ? "Sync Now" : "Try Again") {
                    model.refresh()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    private var toolbarStatusColor: Color {
        guard let envelope = model.envelope,
              envelope.tools.contains(where: { !$0.limits.isEmpty }) else {
            return model.phoneIsReachable ? .cyan : .gray
        }
        return model.errorMessage != nil || model.isStale ? .orange : .green
    }

    private var toolbarStatusDescription: String {
        guard let envelope = model.envelope,
              envelope.tools.contains(where: { !$0.limits.isEmpty }) else {
            return model.phoneIsReachable ? "iPhone connected" : "iPhone unavailable"
        }
        return model.errorMessage != nil || model.isStale
            ? "Showing saved limits"
            : "Limits are current"
    }
}

private struct ToolSectionHeader: View {
    let tool: WatchToolQuotaSnapshot
    let isStale: Bool
    let showsRefresh: Bool
    let isRefreshing: Bool
    let refreshStatusColor: Color
    let refreshStatusDescription: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: tool.symbolName ?? "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
            Text(tool.displayName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            if isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("May be out of date")
            }
            Spacer(minLength: 4)
            if showsRefresh {
                Button(action: onRefresh) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if isRefreshing {
                                ProgressView()
                                    .tint(.primary)
                                    .scaleEffect(0.72)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .frame(width: 22, height: 22)

                        if !isRefreshing {
                            Circle()
                                .fill(refreshStatusColor)
                                .frame(width: 6, height: 6)
                                .overlay {
                                    Circle().stroke(.black.opacity(0.45), lineWidth: 1)
                                }
                                .offset(x: 2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh all limits")
                .accessibilityValue(refreshStatusDescription)
                .disabled(isRefreshing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

private struct WatchQuotaRow: View {
    let tool: WatchToolQuotaSnapshot
    let limit: WatchQuotaSnapshot
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                ConcentricQuotaRing(
                    primaryRemaining: limit.primary.remainingPercent,
                    secondaryRemaining: limit.secondary?.remainingPercent,
                    size: 56,
                    isStale: isStale
                ) {
                    Image(systemName: tool.symbolName ?? "sparkles")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                }

                QuotaDurationTags(limit: limit)
                    .frame(maxWidth: 60)
            }
            .frame(width: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(limit.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("\(Int(limit.effectiveRemainingPercent.rounded()))% remaining")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(constrainingColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                WatchQuotaProgressBar(
                    remainingPercent: limit.constrainingWindow.remainingPercent,
                    color: constrainingColor
                )

                if isStale {
                    Label("Saved data", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let resetAt = limit.constrainingWindow.resetAt {
                    Text("Resets \(resetAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } else {
                    Text("Reset unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.secondary.opacity(0.13), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

private struct WatchQuotaProgressBar: View {
    let remainingPercent: Double
    let color: Color

    private var fraction: Double {
        min(1, max(0, remainingPercent / 100))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct QuotaDetailView: View {
    let tool: WatchToolQuotaSnapshot
    let limit: WatchQuotaSnapshot

    var body: some View {
        List {
            if isStale {
                Label("Showing saved data", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.orange.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .listRowInsets(
                        EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6)
                    )
                    .listRowBackground(Color.clear)
            }

            detailHero
                .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 6, trailing: 6))
                .listRowBackground(Color.clear)

            QuotaWindowPanel(window: limit.primary, role: .primary)
                .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                .listRowBackground(Color.clear)

            if let secondary = limit.secondary {
                QuotaWindowPanel(window: secondary, role: .secondary)
                    .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                    .listRowBackground(Color.clear)
            }

            detailFooter
                .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 8, trailing: 8))
                .listRowBackground(Color.clear)
        }
        .navigationTitle(limit.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailHero: some View {
        VStack(spacing: 6) {
            ConcentricQuotaRing(
                primaryRemaining: limit.primary.remainingPercent,
                secondaryRemaining: limit.secondary?.remainingPercent,
                size: 84,
                isStale: isStale
            ) {
                Image(systemName: tool.symbolName ?? "sparkles")
                    .font(.system(size: 29, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }

            QuotaDurationTags(limit: limit)

            Text(tool.displayName)
                .font(.headline)
                .lineLimit(1)

            Text("\(Int(limit.effectiveRemainingPercent.rounded()))% remaining")
                .font(.caption.weight(.semibold))
                .foregroundStyle(constrainingColor)
                .monospacedDigit()
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var detailFooter: some View {
        HStack(spacing: 5) {
            if let planType = limit.planType, !planType.isEmpty {
                Text(planType.capitalized)
                Text("·")
                    .accessibilityHidden(true)
            }
            Text("Updated \(tool.sourceUpdatedAt, style: .relative)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(footerAccessibilityLabel)
    }

    private var constrainingColor: Color {
        switch limit.constrainingWindowRole {
        case .primary:
            UsagePalette.primary(remainingPercent: limit.constrainingWindow.remainingPercent)
        case .secondary:
            UsagePalette.secondary(remainingPercent: limit.constrainingWindow.remainingPercent)
        }
    }

    private var footerAccessibilityLabel: String {
        var value = "Updated \(tool.sourceUpdatedAt.formatted(.relative(presentation: .named)))"
        if let planType = limit.planType, !planType.isEmpty {
            value = "Plan \(planType.capitalized), \(value)"
        }
        return value
    }

    private var isStale: Bool {
        Date().timeIntervalSince(tool.sourceUpdatedAt) > 30 * 60
    }
}

private struct QuotaWindowPanel: View {
    let window: WatchQuotaWindowSnapshot
    let role: QuotaWindowTag.Role

    private var color: Color {
        switch role {
        case .primary:
            UsagePalette.primary(remainingPercent: window.remainingPercent)
        case .secondary:
            UsagePalette.secondary(remainingPercent: window.remainingPercent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                QuotaWindowTag(window: window, role: role)
                Spacer(minLength: 4)
                Text("\(Int(window.remainingPercent.rounded()))% remaining")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            WatchQuotaProgressBar(
                remainingPercent: window.remainingPercent,
                color: color
            )
            .frame(height: 5)

            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
                Text("Resets")
                Spacer(minLength: 4)
                if let resetAt = window.resetAt {
                    Text(resetAt, style: .relative)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text("Unavailable")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
