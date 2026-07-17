import SwiftUI

@available(macOS 14.0, *)
struct HUDView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: UsageStore
    @ObservedObject var agentStore: CodexAgentStore
    @ObservedObject var settings: HUDSettings
    @ObservedObject var updateController: UpdateController
    let openTool: (AIToolDescriptor) -> Void
    let resizePanel: (CGSize) -> Void
    @State private var isPanelHovered = false
    @State private var refreshRotation = 0.0

    private var snapshots: [QuotaSnapshot] {
        switch store.state {
        case let .current(values), let .stale(values, _): settings.ordered(values)
        default: []
        }
    }

    private var desiredSize: CGSize {
        switch store.state {
        case .current, .stale:
            CGSize(width: HUDMetrics.railWidth, height: HUDMetrics.railHeight(rowCount: snapshots.count))
        default:
            HUDMetrics.messageSize
        }
    }

    private var scaledSize: CGSize {
        HUDMetrics.scaledSize(desiredSize, scale: settings.scale)
    }

    private var hasCriticalQuota: Bool {
        snapshots.contains {
            QuotaSeverity(remainingPercent: $0.remainingPercent).showsScaryGlow
                || QuotaSeverity(
                    remainingPercent: $0.secondaryWindow?.remainingPercent ?? 100
                ).showsScaryGlow
        }
    }

    var body: some View {
        content
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .frame(width: desiredSize.width, height: desiredSize.height)
            .background {
                panelShape
                    .fill(.regularMaterial)
                    .opacity(isPanelHovered ? 1 : 0)
            }
            .overlay {
                ZStack {
                    panelShape
                        .stroke(.separator.opacity(isPanelHovered ? 0.42 : 0), lineWidth: 0.5)
                    if hasCriticalQuota {
                        panelShape
                            .stroke(Color.red.opacity(0.86), lineWidth: 1.5)
                            .shadow(color: .red, radius: 8)
                            .shadow(color: .red.opacity(0.8), radius: 18)
                            .accessibilityHidden(true)
                    }
                }
            }
            .shadow(color: .black.opacity(isPanelHovered ? 0.16 : 0), radius: 18, y: 8)
            .contentShape(panelShape)
            .onHover { isHovered in
                isPanelHovered = isHovered
                guard isHovered else { return }
                Task { await store.refreshIfNeeded(maximumAge: 5) }
            }
            .animation(.easeOut(duration: 0.18), value: isPanelHovered)
            .opacity(
                HUDMetrics.contentOpacity(
                    configured: settings.opacity,
                    isHovered: isPanelHovered,
                    isCritical: hasCriticalQuota
                )
            )
            .scaleEffect(settings.scale)
            .frame(width: scaledSize.width, height: scaledSize.height)
            .task(id: snapshots.map(\.id)) {
                settings.registerBuckets(snapshots.map(\.id))
            }
            .onAppear { resizePanel(scaledSize) }
            .onChange(of: scaledSize) { _, size in resizePanel(size) }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .connecting:
            statusView(title: "Connecting…", symbol: "arrow.triangle.2.circlepath")
        case .signedOut:
            messageView(title: "Sign in through ChatGPT", symbol: "person.crop.circle.badge.exclamationmark", actionTitle: "Open ChatGPT") {
                openTool(.descriptor(for: .chatGPT))
            }
        case let .unavailable(message):
            messageView(title: message, symbol: "bolt.horizontal.circle", actionTitle: "Open ChatGPT") {
                openTool(.descriptor(for: .chatGPT))
            }
        case .empty:
            messageView(title: "No usage limits", symbol: "circle.dotted", actionTitle: "Retry") {
                Task { await store.refresh() }
            }
        case .current:
            quotaRail(isStale: false)
        case .stale:
            quotaRail(isStale: true)
        }
    }

    private func quotaRail(isStale: Bool) -> some View {
        quotaColumn(isStale: isStale)
    }

    private func quotaColumn(isStale: Bool) -> some View {
        VStack(spacing: 7) {
            if snapshots.isEmpty {
                Text("All usage hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: HUDMetrics.itemSpacing) {
                        ForEach(snapshots) { snapshot in
                            QuotaRowView(
                                snapshot: snapshot,
                                agentPhase: snapshot.toolID == .chatGPT ? agentStore.phase : .idle,
                                agentTaskID: snapshot.toolID == .chatGPT
                                    ? agentStore.targetTask?.id
                                    : nil,
                                openTool: openTool,
                                openAgentTask: { taskID in
                                    agentStore.acknowledge(taskID: taskID)
                                    AIToolLauncher.openCodexTask(id: taskID)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .opacity(isStale ? 0.62 : 1)
            }

            Divider().opacity(isPanelHovered ? 0.45 : 0)
            footer(isStale: isStale)
        }
    }

    private func footer(isStale: Bool) -> some View {
        HStack(spacing: 6) {
            refreshButton
            if isStale {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .help("Usage may be out of date")
                    .accessibilityLabel("Usage may be out of date")
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Usage is current")
            }
            settingsLink
        }
        .padding(.horizontal, 3)
        .frame(height: 24)
        .opacity(HUDMetrics.controlOpacity(isHovered: isPanelHovered))
        .allowsHitTesting(isPanelHovered)
    }

    private var refreshButton: some View {
        Button {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.45)) {
                    refreshRotation += 360
                }
            }
            Task {
                async let usageRefresh: Void = store.refresh()
                async let agentRefresh: Void = agentStore.refresh()
                _ = await (usageRefresh, agentRefresh)
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(refreshRotation))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Refresh usage and Codex status")
        .accessibilityLabel("Refresh usage and Codex status")
    }

    private var settingsLink: some View {
        SettingsLink {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                if updateController.canInstallUpdate {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open settings")
        .accessibilityLabel("Open settings")
        .accessibilityValue(
            updateController.canInstallUpdate ? "New version available" : ""
        )
    }

    private func iconButton(
        _ label: String,
        symbol: String,
        showsBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                if showsBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(showsBadge ? "New version available" : "")
    }

    private func statusView(title: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Label(title, systemImage: symbol).font(.headline)
            footer(isStale: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageView(
        title: String,
        symbol: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            footer(isStale: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum HUDMetrics {
    static let railWidth: CGFloat = 84
    static let messageSize = CGSize(width: 220, height: 176)
    static let itemSpacing: CGFloat = 10

    static func railHeight(rowCount: Int) -> CGFloat {
        let additionalGapHeight = CGFloat(max(0, rowCount - 1)) * (itemSpacing - 2)
        return min(450, max(120, 63 + CGFloat(rowCount) * 78 + additionalGapHeight))
    }

    static func scaledSize(_ size: CGSize, scale: Double) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func contentOpacity(
        configured: Double,
        isHovered: Bool,
        isCritical: Bool = false
    ) -> Double {
        if isHovered { return 1 }
        if isCritical { return max(configured, 0.92) }
        return configured
    }

    static func controlOpacity(isHovered: Bool) -> Double {
        isHovered ? 1 : 0
    }
}
