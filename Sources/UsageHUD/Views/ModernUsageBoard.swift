import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An AI tool as Modern shows it: its limits, or what it needs when it has
/// no reading.
struct ModernToolEntry: Identifiable {
    let id: AIToolID
    /// Its limits in display order; empty when it has no reading.
    let limits: [QuotaSnapshot]
    /// What the tool needs, for a tool without a reading.
    var status: LocalToolGuidance.Presentation? = nil
}

/// The AI tools Modern shows, in the user's order: every tool with a
/// reading and every supported tool found on this Mac, so a tool appears
/// as soon as it's there rather than in a separate list.
@MainActor
enum ModernToolList {
    static func entries(store: UsageStore, settings: HUDSettings,
                        localToolStatus: LocalToolStatusRegistry?,
                        includingHidden: Bool) -> [ModernToolEntry] {
        let snapshots = includingHidden
            ? settings.inDisplayOrder(store.visibleSnapshots)
            : settings.ordered(store.visibleSnapshots)
        var order: [AIToolID] = []
        var byTool: [AIToolID: [QuotaSnapshot]] = [:]
        for snapshot in snapshots {
            if byTool[snapshot.toolID] == nil { order.append(snapshot.toolID) }
            byTool[snapshot.toolID, default: []].append(snapshot)
        }
        var entries = order.map { ModernToolEntry(id: $0, limits: byTool[$0] ?? []) }
        let reading = Set(store.visibleSnapshots.map(\.toolID))
        let status = { (id: AIToolID) in Self.status(for: id, store: store, localToolStatus: localToolStatus) }
        for guidance in LocalToolGuidance.listed(order: settings.toolOrder, status: status)
        where !reading.contains(guidance.id) {
            if !includingHidden {
                // Switched off: hidden, or an opt-in tool not turned on.
                if settings.hiddenToolIDs.contains(guidance.id) { continue }
                if LocalToolOptIn.optInToolIDs.contains(guidance.id), !LocalToolOptIn.isEnabled(guidance.id) { continue }
            }
            entries.append(ModernToolEntry(id: guidance.id, limits: [],
                                           status: guidance.presentation(for: status(guidance.id))))
        }
        let rank = Dictionary(settings.toolOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated().sorted { left, right in
            let l = rank[left.element.id] ?? Int.max, r = rank[right.element.id] ?? Int.max
            return l == r ? left.offset < right.offset : l < r
        }.map(\.element)
    }

    static func status(for id: AIToolID, store: UsageStore, localToolStatus: LocalToolStatusRegistry?) -> LocalToolStatus {
        if store.visibleSnapshots.contains(where: { $0.toolID == id }) { return .connected }
        if id == .chatGPT { return .signedOut }
        return localToolStatus?.status(for: id) ?? .unknown
    }
}

/// Modern's Usage page body: a card for every AI tool with a reading, a bar
/// for each limit, then the same cards for tools on this Mac that can't
/// show usage, each with what it needs. Editing keeps the same
/// layout: a switch shows or hides each tool and each limit, and cards drag
/// into a new order.
@available(macOS 14.0, *)
struct ModernUsageBoard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    var localToolStatus: LocalToolStatusRegistry?
    let editing: Bool
    /// What each tool is working on now, shown on its card.
    var liveWork: LiveWorkMonitor? = nil
    var openBranches: (() -> Void)? = nil
    @State private var dropTarget: AIToolID?
    @State private var optInRevision = 0

    private static let spacing: CGFloat = 14

    var body: some View {
        let tools = ModernToolList.entries(store: store, settings: settings,
                                           localToolStatus: localToolStatus, includingHidden: editing)
        let reading = tools.filter { !$0.limits.isEmpty }
        let waiting = tools.filter(\.limits.isEmpty)
        // One card a row: each tool reads top to bottom, its limits, free
        // resets and current work together.
        let perRow = 1
        VStack(alignment: .leading, spacing: 26) {
            cards(reading, perRow: perRow)
            // Tools on this Mac that can't show usage, in the same cards,
            // after the ones that can.
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Not connected")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 4)
                    cards(waiting, perRow: perRow)
                }
            }
            if editing {
                Text("usAIge reads each tool's limits with its sign-in on this Mac. Sign-ins stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func cards(_ tools: [ModernToolEntry], perRow: Int) -> some View {
        if tools.isEmpty {
            ModernCard {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // Each row is as tall as its tallest card.
            Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                ForEach(Array(stride(from: 0, to: tools.count, by: perRow)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<(start + perRow), id: \.self) { index in
                            if index < tools.count {
                                card(tools[index])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: tools.map(\.id))
        }
    }

    private var emptyText: String {
        switch store.state {
        case .connecting: "Connecting to your AI tools…"
        case .signedOut: UsageState.connectGuidance
        case let .unavailable(message): message
        default: store.visibleSnapshots.isEmpty
            ? "No usage readings yet. Choose Edit to find or connect your AI tools."
            : "All usage readings are hidden. Choose Edit to show them."
        }
    }

    // MARK: Cards

    private func card(_ entry: ModernToolEntry) -> some View {
        let tool = AIToolDescriptor.descriptor(for: entry.id)
        let isShown = isToolShown(entry.id)
        let limits = editing ? entry.limits : entry.limits.filter { !settings.hiddenBucketIDs.contains($0.id) }
        return ModernCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if editing {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .help("Drag to reorder")
                            .accessibilityHidden(true)
                    }
                    AIToolIcon(tool: tool, size: 18)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name).font(.headline).lineLimit(1)
                        if limits.count == 1, let only = limits.first {
                            Text(only.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if editing { toolSwitch(entry.id, name: tool.name) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let status = entry.status {
                        ModernToolStatusText(status: status)
                    }
                    ForEach(limits) { limit in
                        limitRows(limit, showsName: limits.count > 1, toolShown: isShown)
                    }
                    let credits = settings.showsResetCredits ? entry.limits.availableResets() : []
                    if !credits.isEmpty {
                        Divider().padding(.vertical, 2)
                        ModernResetCredits(credits: credits)
                    }
                    if let liveWork, !editing {
                        ModernToolWork(monitor: liveWork, tool: entry.id, openBranches: openBranches)
                    }
                }
                .opacity(isShown ? 1 : 0.4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: dropTarget == entry.id ? 2 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
        .modifier(ReorderableCard(enabled: editing, id: entry.id, dropTarget: $dropTarget) { moved, target in
            withAnimation(.snappy(duration: 0.22)) { settings.moveTool(moved, to: target) }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tool.name)
    }

    @ViewBuilder
    private func limitRows(_ limit: QuotaSnapshot, showsName: Bool, toolShown: Bool) -> some View {
        let isShown = !settings.hiddenBucketIDs.contains(limit.id)
        VStack(alignment: .leading, spacing: 7) {
            if showsName {
                HStack(spacing: 8) {
                    Text(limit.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if editing {
                        Toggle("Show \(limit.displayName)", isOn: Binding(
                            get: { isShown },
                            set: { visible in
                                if visible { settings.hiddenBucketIDs.remove(limit.id) }
                                else { settings.hiddenBucketIDs.insert(limit.id) }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!toolShown)
                        .help("Show this limit on the rail and in usAIge")
                    }
                }
            }
            Group {
                ModernQuotaBar(window: limit.primaryWindow)
                if let secondary = limit.secondaryWindow {
                    ModernQuotaBar(window: secondary)
                }
            }
            .opacity(isShown ? 1 : 0.4)
        }
    }

    /// An opt-in tool's switch decides whether usAIge reads its sign-in at
    /// all; every other tool's switch shows or hides it.
    @ViewBuilder
    private func toolSwitch(_ id: AIToolID, name: String) -> some View {
        if LocalToolOptIn.optInToolIDs.contains(id) {
            Toggle("Read \(name) limits", isOn: optInBinding(for: id))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Read \(name) limits with its sign-in on this Mac")
        } else {
            Toggle("Show \(name)", isOn: Binding(
                get: { !settings.hiddenToolIDs.contains(id) },
                set: { visible in
                    withAnimation(.snappy(duration: 0.2)) {
                        if visible { settings.hiddenToolIDs.remove(id) } else { settings.hiddenToolIDs.insert(id) }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help("Show \(name) on the rail and in usAIge")
        }
    }

    private func optInBinding(for id: AIToolID) -> Binding<Bool> {
        Binding(
            get: { _ = optInRevision; return LocalToolOptIn.isEnabled(id) },
            set: { enabled in
                LocalToolOptIn.setEnabled(enabled, for: id)
                if enabled { settings.hiddenToolIDs.remove(id) } else { settings.hiddenToolIDs.insert(id) }
                optInRevision += 1
                Task { await store.refresh() }
            }
        )
    }

    /// Whether the tool shows on the rail and in usAIge: not hidden, and
    /// turned on if it's an opt-in tool.
    private func isToolShown(_ id: AIToolID) -> Bool {
        _ = optInRevision
        if LocalToolOptIn.optInToolIDs.contains(id), !LocalToolOptIn.isEnabled(id) { return false }
        return !settings.hiddenToolIDs.contains(id)
    }

}

/// What a tool without a reading needs: a warning for a problem, such as an
/// expired sign-in, and plain text for a tool that isn't connected yet.
struct ModernToolStatusText: View {
    let status: LocalToolGuidance.Presentation
    var font: Font = .callout

    var body: some View {
        if status.isProblem {
            Label(status.text, systemImage: "exclamationmark.triangle.fill")
                .font(font)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(status.text)
                .font(font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Drag one card onto another to put it there, while editing.
@available(macOS 14.0, *)
private struct ReorderableCard: ViewModifier {
    let enabled: Bool
    let id: AIToolID
    @Binding var dropTarget: AIToolID?
    let move: (AIToolID, AIToolID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first else { return false }
                    move(AIToolID(rawValue: raw), id)
                    return true
                } isTargeted: { targeted in
                    if targeted { dropTarget = id } else if dropTarget == id { dropTarget = nil }
                }
        } else {
            content
        }
    }
}

/// What a tool is working on now: each branch or worktree it's in, with its
/// processes, ports and current task, and the memory it all uses.
@available(macOS 14.0, *)
private struct ModernToolWork: View {
    @ObservedObject var monitor: LiveWorkMonitor
    let tool: AIToolID
    var openBranches: (() -> Void)?

    var body: some View {
        let sessions = monitor.summary.sessions(for: tool)
        let memory = monitor.summary.memoryBytes(for: tool)
        if !sessions.isEmpty || memory > 0 {
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sessions.isEmpty ? "Memory" : "Working now")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if memory > 0 {
                        Text(LiveWorkText.memory(memory))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if !sessions.isEmpty {
                    LiveSessionList(sessions: sessions).font(.callout)
                    if let openBranches {
                        Button("All branches and worktrees…", action: openBranches)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }
}
