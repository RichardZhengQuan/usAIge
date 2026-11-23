import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared by the provider mark, status symbols, quota periods, and expanded detail rows.
struct UsageCardColumns {
    static let standard = Self(markerWidth: 32, spacing: 8)
    let markerWidth: CGFloat
    let spacing: CGFloat
    var contentInset: CGFloat { markerWidth + spacing }
}

private struct UsageCardColumnsKey: EnvironmentKey {
    static let defaultValue: UsageCardColumns? = nil
}

extension EnvironmentValues {
    var usageCardColumns: UsageCardColumns? {
        get { self[UsageCardColumnsKey.self] }
        set { self[UsageCardColumnsKey.self] = newValue }
    }
}

private struct UsageCardLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UsageCardColumns.standard.spacing) {
            configuration.icon.frame(width: UsageCardColumns.standard.markerWidth)
            configuration.title
        }
    }
}

/// An AI tool as Modern shows it: its limits, or what it needs when it has
/// no reading.
struct ModernToolEntry: Identifiable {
    let id: AIToolID
    /// Its limits in display order; empty when it has no reading.
    let limits: [QuotaSnapshot]
    var connection: LocalToolStatus? = nil

    var status: LocalToolGuidance.Presentation? {
        connection.map { state in
            LocalToolGuidance.supported.first { $0.id == id }?.presentation(for: state)
                ?? .init(text: "No local usage reading is available for this tool.", isProblem: false)
        }
    }

    var connectionSummary: String? { connection.map { UsageCardSummary.connection($0, tool: id) } }
}

enum UsageCardSummary {
    /// Several model limits often share a reset. Preserve the displayed window
    /// order, and identify the model when two windows of the same length differ.
    static func resets(_ limits: [QuotaSnapshot], now: Date, locale: Locale = AppLanguage.current.locale) -> String? {
        struct Window: Hashable {
            let tag: String
            let moment: String?
        }
        var windows: [Window] = []
        var names: [Window: String] = [:]
        for limit in limits {
            for window in [limit.primaryWindow, limit.secondaryWindow].compactMap({ $0 }) {
                let key = Window(tag: window.typeTag, moment: ResetMomentText.moment(window.resetAt, now: now, locale: locale))
                if names[key] == nil {
                    windows.append(key)
                    names[key] = limit.displayName
                }
            }
        }
        guard !windows.isEmpty else { return nil }
        let grouped = Dictionary(grouping: windows, by: \.tag)
        var descriptions = windows.prefix(3).map { window in
            let label = grouped[window.tag, default: []].count > 1
                ? "\(names[window] ?? "") \(window.tag)" : window.tag
            return window.moment.map { AppLanguage.format("%@ resets %@", locale: locale, label, $0) }
                ?? AppLanguage.format("%@ reset time unavailable", locale: locale, label)
        }
        let extra = windows.count - descriptions.count
        if extra > 0 { descriptions.append(AppLanguage.format("+%ld more", locale: locale, extra)) }
        return descriptions.joined(separator: "  ·  ")
    }

    static func work(_ summary: LiveWorkSummary, for tool: AIToolID, locale: Locale = AppLanguage.current.locale) -> String? {
        let sessions = summary.sessions(for: tool)
        if let lead = sessions.first {
            let place = lead.repositoryName ?? LiveWorkText.branchLine(lead) ?? lead.title
            var parts = [AppLanguage.text(lead.phase.label, locale: locale), place].filter { !$0.isEmpty }
            if sessions.count > 1 {
                let others = sessions.count - 1
                parts.append(AppLanguage.format(others == 1 ? "%ld other session" : "%ld other sessions", locale: locale, others))
            }
            return parts.joined(separator: " · ")
        }
        let count = summary.appProcesses[tool]?.count ?? 0
        guard count > 0 else { return nil }
        let processes = AppLanguage.format(count == 1 ? "%ld process" : "%ld processes", locale: locale, count)
        let bytes = summary.memoryBytes(for: tool)
        return bytes == 0 ? processes : processes + " · " + AppLanguage.format("%@ in use", locale: locale, LiveWorkText.memory(bytes))
    }

    static func connection(_ status: LocalToolStatus, tool: AIToolID) -> String {
        switch status {
        case .unknown: "Checking for usage…"
        case .notInstalled: "No local reading"
        case .signedOut: tool == .claude ? "Waiting for Claude usage" : "Sign-in required"
        case .credentialExpired: tool == .claude ? "Waiting for Claude usage" : "Sign-in expired"
        case .optInRequired: "Usage reading is off"
        case .apiKeyOnly, .apiKeyHelperSignInExpired: "Checking Claude for plan limits"
        case .keychainAccessDenied: "Credential access blocked"
        case .missingScope: tool == .claude ? "Waiting for Claude usage" : "Usage access required"
        case .rateLimited: "Usage checks are rate limited"
        case .failed: "Unable to read usage"
        case .connected, .connectedThroughClaudeApp, .connectedThroughClaudeAppCache,
             .connectedThroughClaudeBridge, .waitingForClaudeUsage: "Waiting for a quota reading"
        }
    }
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

    static func installedSections(
        installed: Set<AIToolID>, snapshots: [QuotaSnapshot], settings: HUDSettings, editing: Bool,
        status: (AIToolID) -> LocalToolStatus
    ) -> (withReadings: [ModernToolEntry], notConnected: [ModernToolEntry]) {
        let buckets = Dictionary(grouping: settings.inDisplayOrder(snapshots), by: \.toolID)
        var remaining = editing ? installed : installed.subtracting(settings.hiddenToolIDs)
        var withReadings: [ModernToolEntry] = []
        var notConnected: [ModernToolEntry] = []
        for id in settings.toolOrder + AIToolID.builtInIDs where remaining.remove(id) != nil {
            if let limits = buckets[id] {
                withReadings.append(ModernToolEntry(id: id, limits: limits))
                continue
            }
            let reported = status(id)
            // Some providers only detect their sign-in files. An installed app
            // or CLI that hasn't created those files yet still has a card.
            let state: LocalToolStatus = reported == .notInstalled || (id == .chatGPT && reported == .unknown)
                ? .signedOut : reported
            notConnected.append(ModernToolEntry(id: id, limits: [], connection: state))
        }
        return (withReadings, notConnected)
    }
}

@available(macOS 14.0, *)
struct ModernUsageBoard: View {
    @Environment(\.locale) private var locale
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    @StateObject private var localToolStatus: LocalToolStatusRegistry
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
        _localToolStatus = StateObject(wrappedValue: localToolStatus ?? LocalToolStatusRegistry())
        self.editing = editing
        self.liveWork = liveWork
        self.openBranches = openBranches
        self.detectionRevision = detectionRevision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let installed = localToolStatus.installedTools {
                let sections = ModernToolList.installedSections(
                    installed: installed, snapshots: store.visibleSnapshots, settings: settings,
                    editing: editing, status: localToolStatus.status(for:)
                )
                if sections.withReadings.isEmpty && sections.notConnected.isEmpty {
                    ModernCard {
                        Text(LocalizedStringKey(installed.isEmpty ? "No supported AI tools found on this Mac."
                                              : "All installed tools are hidden. Choose Edit to show them."), bundle: AppLanguage.resourceBundle)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if store.state == .connecting && !editing {
                    ProgressView("Checking usage…").controlSize(.small)
                } else {
                    ForEach(sections.withReadings) { entry in card(entry) }
                    if !sections.notConnected.isEmpty {
                        Text("Not connected")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, 4)
                            .padding(.top, sections.withReadings.isEmpty ? 0 : 12)
                        ForEach(sections.notConnected) { entry in card(entry) }
                    }
                }
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
        let subtitle = limits.count == 1 ? limits.first?.displayName
            : entry.connectionSummary.map { AppLanguage.text($0, locale: locale) }
        let disclosure = Self.disclosure(for: entry.id, editing: editing, saved: $expandedTools)
        let showsDetails = disclosure?.wrappedValue ?? false
        return ModernCard(padding: 16) {
            HStack(alignment: .top, spacing: 10) {
                if editing {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(minHeight: 40)
                        .help(AppLanguage.text("Drag to reorder", locale: locale))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        cardHeader(tool: tool, subtitle: subtitle, disclosure: disclosure)
                        if editing {
                            toolSwitch(entry.id, name: tool.name)
                                .accessibilityIdentifier("usage.visibility.\(entry.id.rawValue)")
                        }
                    }
                    if !showsDetails {
                        VStack(alignment: .leading, spacing: 5) {
                            if !limits.isEmpty {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    if let text = UsageCardSummary.resets(limits, now: context.date, locale: locale) {
                                        Label(text, systemImage: "clock")
                                    }
                                }
                            }
                            if let liveWork {
                                UsageCardWorkSummary(monitor: liveWork, tool: entry.id)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !limits.isEmpty || showsDetails {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(limits) { limit in
                                limitRows(limit, showsName: limits.count > 1, toolShown: isShown)
                            }
                            if showsDetails {
                                Divider()
                                if let status = entry.status, let connection = entry.connection {
                                    UsageConnectionActions(tool: tool, connection: connection, status: status, store: store,
                                                           enableReading: { optInBinding(for: entry.id).wrappedValue = true })
                                } else if limits.isEmpty {
                                    Text("All limits are hidden. Choose Edit to show them.", bundle: AppLanguage.resourceBundle)
                                        .font(.callout).foregroundStyle(.secondary)
                                        .padding(.leading, UsageCardColumns.standard.contentInset)
                                } else {
                                    resetDetails(limits)
                                }
                                if let liveWork {
                                    ModernToolWork(monitor: liveWork, tool: entry.id, openBranches: openBranches)
                                }
                            }
                        }
                        .opacity(editing && !isShown ? 0.55 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .labelStyle(UsageCardLabelStyle())
        .environment(\.usageCardColumns, .standard)
        .overlay {
            RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: dropTarget == entry.id ? 2 : 0)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
        .modifier(ReorderableCard(enabled: editing, id: entry.id, dropTarget: $dropTarget) { moved, target in
            withAnimation(.snappy(duration: 0.22)) { settings.moveTool(moved, to: target) }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tool.name)
    }

    static func disclosure(for id: AIToolID, editing: Bool, saved: Binding<String>) -> Binding<Bool>? {
        guard !editing else { return nil }
        return Binding(
            get: { saved.wrappedValue.split(separator: ",").contains(Substring(id.rawValue)) },
            set: { show in
                var ids = Set(saved.wrappedValue.split(separator: ",").map(String.init))
                if show { ids.insert(id.rawValue) } else { ids.remove(id.rawValue) }
                saved.wrappedValue = ids.sorted().joined(separator: ",")
            }
        )
    }

    @ViewBuilder
    private func cardHeader(tool: AIToolDescriptor, subtitle: String?, disclosure: Binding<Bool>?) -> some View {
        let header = HStack(spacing: UsageCardColumns.standard.spacing) {
            AIToolIcon(tool: tool, size: 18)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: UsageCardColumns.standard.markerWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).font(.headline).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let disclosure {
                Image(systemName: disclosure.wrappedValue ? "chevron.down" : "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)

        if let disclosure {
            Button { disclosure.wrappedValue.toggle() } label: { header.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLanguage.format("%@ details", locale: locale, tool.name))
                .accessibilityValue(AppLanguage.text(disclosure.wrappedValue ? "Expanded" : "Collapsed", locale: locale))
                .accessibilityIdentifier("usage.details.\(tool.id.rawValue)")
                .help(AppLanguage.format(disclosure.wrappedValue ? "Hide %@ details" : "Show %@ details", locale: locale, tool.name))
        } else {
            header.accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func resetDetails(_ limits: [QuotaSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text("Reset details", bundle: AppLanguage.resourceBundle) } icon: { Image(systemName: "clock") }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(limits) { limit in
                if limits.count > 1 {
                    Text(limit.displayName).fontWeight(.medium)
                        .padding(.leading, UsageCardColumns.standard.contentInset)
                }
                resetRow(limit.primaryWindow)
                if let secondary = limit.secondaryWindow { resetRow(secondary) }
            }
            let credits = limits.availableResets()
            if !credits.isEmpty { ModernResetCredits(credits: credits) }
        }
        .font(.callout)
    }

    private func resetRow(_ window: QuotaWindowSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UsageCardColumns.standard.spacing) {
            Text(window.typeTag).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: UsageCardColumns.standard.markerWidth)
            if let reset = window.resetAt {
                Text(reset.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
            } else {
                Text("Reset time unavailable", bundle: AppLanguage.resourceBundle).foregroundStyle(.secondary)
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
                        Toggle(AppLanguage.format("Show %@", locale: locale, limit.displayName), isOn: Binding(
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
                        .help(AppLanguage.text("Show this limit on the floating panel and dashboard", locale: locale))
                    }
                }
                .padding(.leading, UsageCardColumns.standard.contentInset)
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
            Toggle(AppLanguage.format("Read %@ limits", locale: locale, name), isOn: optInBinding(for: id))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(AppLanguage.format("Read %@ limits with its sign-in on this Mac", locale: locale, name))
        } else {
            Toggle(AppLanguage.format("Show %@", locale: locale, name), isOn: Binding(
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
            .help(AppLanguage.format("Show %@ in Usage, Overview, and the floating panel", locale: locale, name))
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

@available(macOS 14.0, *)
private struct UsageCardWorkSummary: View {
    @Environment(\.locale) private var locale
    @ObservedObject var monitor: LiveWorkMonitor
    let tool: AIToolID

    var body: some View {
        if let text = UsageCardSummary.work(monitor.summary, for: tool, locale: locale) {
            Label(text, systemImage: "laptopcomputer")
        }
    }
}

/// A local sign-in needs the installed app. Opening the provider's website
/// would leave its local session unchanged.
enum UsageConnectionAction: Equatable {
    case openApp(URL)
    case download(URL)
    case enableReading

    static func action(for tool: AIToolID, status: LocalToolStatus, installedApp: URL?) -> Self? {
        switch status {
        case .optInRequired:
            return LocalToolOptIn.optInToolIDs.contains(tool) ? .enableReading : nil
        case .waitingForClaudeUsage, .signedOut, .credentialExpired, .missingScope,
             .apiKeyOnly, .apiKeyHelperSignInExpired, .keychainAccessDenied:
            if let installedApp { return .openApp(installedApp) }
            switch tool {
            case .claude: return .download(URL(string: "https://claude.com/download")!)
            case .cursor: return .download(URL(string: "https://cursor.com/download")!)
            default: return nil
            }
        default:
            return nil
        }
    }
}

@available(macOS 14.0, *)
private struct UsageConnectionActions: View {
    @Environment(\.locale) private var locale
    let tool: AIToolDescriptor
    let connection: LocalToolStatus
    let status: LocalToolGuidance.Presentation
    @ObservedObject var store: UsageStore
    let enableReading: () -> Void
    @State private var checkOnReturn = false
    @State private var openFailed = false

    var body: some View {
        let action = UsageConnectionAction.action(for: tool.id, status: connection,
                                                  installedApp: AIToolLauncher.applicationURL(for: tool))
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                message.fixedSize()
                Spacer(minLength: 8)
                controls(action).fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                message
                controls(action).padding(.leading, UsageCardColumns.standard.contentInset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard checkOnReturn else { return }
            checkOnReturn = false
            Task { await store.refresh() }
        }
        .alert(AppLanguage.format("Couldn’t open %@.", locale: locale, tool.name), isPresented: $openFailed) {}
    }

    @ViewBuilder private var message: some View {
        if status.isProblem {
            Label(AppLanguage.text(status.text, locale: locale), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let text = connection == .waitingForClaudeUsage
                ? "In Claude, open Settings → Usage. usAIge picks up the new reading automatically."
                : status.text
            Text(AppLanguage.text(text, locale: locale))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, UsageCardColumns.standard.contentInset)
        }
    }

    private func controls(_ action: UsageConnectionAction?) -> some View {
        HStack(spacing: 8) {
            switch action {
            case let .openApp(url):
                Button(AppLanguage.format("Open %@", locale: locale, tool.name)) { open(url) }
            case let .download(url):
                Button(AppLanguage.format("Get %@", locale: locale, tool.name)) { open(url) }
            case .enableReading:
                Button(AppLanguage.text("Enable Usage Reading", locale: locale), action: enableReading)
            case nil:
                EmptyView()
            }
            if connection != .optInRequired {
                Button(AppLanguage.text(store.isManuallyRefreshing ? "Checking…" : "Check Again", locale: locale)) {
                    Task { await store.refresh() }
                }
                .disabled(store.isManuallyRefreshing || connection == .rateLimited)
                .accessibilityIdentifier("usage.recheck.\(tool.id.rawValue)")
            }
        }
        .controlSize(.small)
    }

    private func open(_ url: URL) {
        checkOnReturn = NSWorkspace.shared.open(url)
        openFailed = !checkOnReturn
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
                    Label {
                        Text(LocalizedStringKey(sessions.isEmpty ? "Memory" : "Working now"), bundle: AppLanguage.resourceBundle)
                    } icon: {
                        Image(systemName: sessions.isEmpty ? "memorychip" : "laptopcomputer")
                    }
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
                        Button(action: openBranches) { Text("All branches and worktrees…", bundle: AppLanguage.resourceBundle) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .padding(.leading, UsageCardColumns.standard.contentInset)
                    }
                }
            }
        }
    }
}
