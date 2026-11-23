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

@MainActor
enum ModernToolList {
    /// Quota sources can include paired remote tools. Overview retains those
    /// readings, while the Usage page selects its cards from the local inventory.
    static func readingEntries(_ snapshots: [QuotaSnapshot]) -> [ModernToolEntry] {
        var buckets: [AIToolID: [QuotaSnapshot]] = [:]
        var order: [AIToolID] = []
        for snapshot in snapshots {
            if buckets[snapshot.toolID] == nil { order.append(snapshot.toolID) }
            buckets[snapshot.toolID, default: []].append(snapshot)
        }
        return order.map { ModernToolEntry(id: $0, limits: buckets[$0] ?? []) }
    }

    static func installedEntries(
        installed: Set<AIToolID>, snapshots: [QuotaSnapshot], order: [AIToolID],
        status: (AIToolID) -> LocalToolStatus
    ) -> [ModernToolEntry] {
        let buckets = Dictionary(grouping: snapshots, by: \.toolID)
        let tools = order + AIToolID.builtInIDs.filter { !order.contains($0) }
        return tools.filter(installed.contains).map { id in
            let limits = buckets[id] ?? []
            guard limits.isEmpty else { return ModernToolEntry(id: id, limits: limits) }
            let guidance = LocalToolGuidance.supported.first { $0.id == id }
            let reported = status(id)
            // Some providers only detect their sign-in files. An installed app
            // or CLI that hasn't created those files yet still has a card.
            let state: LocalToolStatus = reported == .notInstalled || (id == .chatGPT && reported == .unknown)
                ? .signedOut : reported
            let detail = guidance?.presentation(for: state)
                ?? .init(text: "No local usage reading is available for this tool.", isProblem: false)
            return ModernToolEntry(id: id, limits: [], status: detail)
        }
    }
}

@available(macOS 14.0, *)
struct ModernUsageBoard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    @ObservedObject private var localToolStatus: LocalToolStatusRegistry
    let editing: Bool
    var liveWork: LiveWorkMonitor?
    var openBranches: (() -> Void)?
    var detectionRevision: Int
    static let expandedDefaultsKey = "usageHUD.expandedResetTools"
    @AppStorage(expandedDefaultsKey) private var expandedTools = ""
    @State private var dropTarget: AIToolID?
    @State private var optInRevision = 0

    init(store: UsageStore, settings: HUDSettings, localToolStatus: LocalToolStatusRegistry?,
         editing: Bool, liveWork: LiveWorkMonitor? = nil, openBranches: (() -> Void)? = nil,
         detectionRevision: Int = 0) {
        self.store = store
        self.settings = settings
        self.localToolStatus = localToolStatus ?? LocalToolStatusRegistry()
        self.editing = editing
        self.liveWork = liveWork
        self.openBranches = openBranches
        self.detectionRevision = detectionRevision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let installed = localToolStatus.installedTools {
                let entries = ModernToolList.installedEntries(
                    installed: installed, snapshots: settings.inDisplayOrder(store.visibleSnapshots),
                    order: settings.toolOrder, status: localToolStatus.status(for:)
                )
                if entries.isEmpty {
                    ModernCard {
                        Text("No supported AI tools found on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(entries) { entry in card(entry) }
            } else {
                ProgressView("Checking installed tools…").controlSize(.small)
            }
            if editing {
                Text("usAIge reads each tool's limits with its sign-in on this Mac. Sign-ins stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: detectionRevision) {
            await localToolStatus.refreshInstallations()
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
                    if limits.isEmpty && !entry.limits.isEmpty {
                        Text("All limits are hidden. Choose Edit to show them.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    resetDetails(for: entry, limits: limits, name: tool.name)
                    if let liveWork, !editing {
                        ModernToolWork(monitor: liveWork, tool: entry.id, openBranches: openBranches)
                    }
                }
                .opacity(editing && !isShown ? 0.55 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func resetDetails(for entry: ModernToolEntry, limits: [QuotaSnapshot], name: String) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedTools.split(separator: ",").contains(Substring(entry.id.rawValue)) },
            set: { show in
                var ids = Set(expandedTools.split(separator: ",").map(String.init))
                if show { ids.insert(entry.id.rawValue) } else { ids.remove(entry.id.rawValue) }
                expandedTools = ids.sorted().joined(separator: ",")
            }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if limits.isEmpty {
                    Text("No reset details available.").foregroundStyle(.secondary)
                }
                ForEach(limits) { limit in
                    if limits.count > 1 {
                        Text(limit.displayName).fontWeight(.medium)
                    }
                    resetRow(limit.primaryWindow)
                    if let secondary = limit.secondaryWindow { resetRow(secondary) }
                }
                let credits = settings.showsResetCredits ? limits.availableResets() : []
                if !credits.isEmpty { ModernResetCredits(credits: credits) }
            }
            .font(.callout)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Reset details").font(.callout.weight(.medium))
                .accessibilityLabel("\(name) reset details")
        }
        .accessibilityIdentifier("usage.resets.\(entry.id.rawValue)")
    }

    private func resetRow(_ window: QuotaWindowSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(window.typeTag).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let reset = window.resetAt {
                Text(reset.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("Reset time unavailable").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func limitRows(_ limit: QuotaSnapshot, showsName: Bool, toolShown: Bool) -> some View {
        let isShown = !settings.hiddenBucketIDs.contains(limit.id)
        VStack(alignment: .leading, spacing: 7) {
            if showsName || editing {
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
                        .help("Show this limit on the floating panel and dashboard")
                    }
                }
            }
            Group {
                ModernQuotaBar(window: limit.primaryWindow, showsReset: false)
                if let secondary = limit.secondaryWindow {
                    ModernQuotaBar(window: secondary, showsReset: false)
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
            .help("Show \(name) on the floating panel and overview")
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
@available(macOS 14.0, *)
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
