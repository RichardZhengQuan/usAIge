import AppKit
import Combine
import SwiftUI

/// Usage, resource details, repository work, and cleanup share one overview.
/// Cleanup belongs to the window’s store and presents progress independently.
@available(macOS 14.0, *)
struct MainRootView: View {
    @ObservedObject var store: BranchesStore
    var liveWork: LiveWorkMonitor?
    var agentStore: CodexAgentStore?
    var usageStore: UsageStore?
    var settings: HUDSettings? = nil
    @ObservedObject var presentation: BranchesPaperweightPresentation
    var settingsContent: AnyView? = nil
    /// The pairing steps Modern's Usage page shows to connect a remote tool.
    var connectContent: AnyView? = nil
    /// Syncing with iPhone and Apple Watch, shown as Modern's own page.
    var syncContent: AnyView? = nil
    var localToolStatus: LocalToolStatusRegistry? = nil
    var updateController: UpdateController? = nil
    var openSettings: () -> Void
    @AppStorage(InterfaceStyle.defaultsKey) private var interfaceStyle = InterfaceStyle.standard
    @Environment(\.locale) private var locale

    private var cleanBadge: Text {
        Text(verbatim: store.isDeleting ? "…" : store.cleanableSpace.label(locale: locale))
    }

    private var modernSelection: Binding<ModernPage?> {
        Binding(get: { presentation.selectedSection == .settings ? nil : presentation.modernPage },
                set: { page in if let page { presentation.open(page) } })
    }

    /// Overview sums up every page under the app's name; the rest carry the
    /// same titles as Overview's sections.
    static let modernGroups: [(title: String?, pages: [ModernPage])] = [
        ("usAIge", [.overview]),
        ("AI tools", [.usage]),
        ("Running", [.thisMac, .memory, .storage, .clean, .branches, .worktrees]),
        ("Devices", [.devices]),
    ]

    static func color(for page: ModernPage) -> Color {
        switch page {
        case .overview: Color(nsColor: .systemBlue)
        case .usage: Color(nsColor: .systemOrange)
        case .thisMac: ModernPalette.cpu
        case .memory: ModernPalette.memory
        case .storage: Color(nsColor: .systemGray)
        case .clean: Color(nsColor: .systemTeal)
        case .branches: Color(nsColor: .systemGreen)
        case .worktrees: Color(nsColor: .systemTeal)
        case .devices: Color(nsColor: .systemIndigo)
        }
    }

    private var selectedSection: Binding<OverviewSection?> {
        Binding(get: { presentation.selectedSection }, set: { section in
            guard let section else { return }
            focus(section)
        })
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if interfaceStyle == .modern {
                    List(selection: modernSelection) {
                        // Grouped like System Settings: the overview, AI
                        // tools, running resources, then devices. A native
                        // sidebar section collapses when its header is
                        // clicked, so titles are plain rows that can't.
                        ForEach(Self.modernGroups, id: \.pages) { group in
                            if let title = group.title {
                                Text(LocalizedStringKey(title), bundle: AppLanguage.resourceBundle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 14)
                                    .selectionDisabled()
                                    .allowsHitTesting(false)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(group.pages) { page in
                                Label {
                                    Text(LocalizedStringKey(page.title), bundle: AppLanguage.resourceBundle)
                                } icon: {
                                    ModernIcon(symbol: page.symbol, color: Self.color(for: page), size: 20)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.open(page) }
                                .accessibilityAction { presentation.open(page) }
                                .badge(page == .clean ? cleanBadge : nil)
                                .tag(page)
                            }
                        }
                    }
                } else {
                    List(selection: selectedSection) {
                        Section("usAIge") {
                            navigationItem("Overview", symbol: "square.grid.2x2", section: .overview)
                                .tag(OverviewSection.overview)
                        }
                        Section {
                            navigationItem(ModernPage.thisMac.title, symbol: ModernPage.thisMac.symbol, section: .thisMac)
                                .tag(OverviewSection.thisMac)
                            navigationItem("Resources", symbol: "chart.pie", section: .resources)
                                .tag(OverviewSection.resources)
                            navigationItem("Clean", symbol: ModernPage.clean.symbol, section: .clean)
                                .badge(cleanBadge)
                                .tag(OverviewSection.clean)
                            navigationItem("Branches & Worktrees", symbol: "arrow.triangle.branch", section: .branches)
                                .tag(OverviewSection.branches)
                        } header: {
                            Text("Running", bundle: AppLanguage.resourceBundle)
                        }
                        if syncContent != nil {
                            Section("Devices") {
                                navigationItem(ModernPage.devices.title, symbol: ModernPage.devices.symbol, section: .devices)
                                    .tag(OverviewSection.devices)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let updateController {
                        SidebarUpdateReminderView(updateController: updateController)
                    }

                    List(selection: selectedSection) {
                        navigationItem("Settings", symbol: "gearshape", section: .settings)
                            .tag(OverviewSection.settings)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: 48)
                }
            }
        } detail: {
            if presentation.selectedSection == .settings, let settingsContent {
                settingsContent.navigationTitle("Settings")
            } else if interfaceStyle == .modern {
                modernPage
            } else if presentation.selectedSection == .clean {
                CleanPage(store: store, presentation: presentation)
            } else if presentation.selectedSection == .thisMac {
                ThisMacPage(liveWork: liveWork).navigationTitle(ModernPage.thisMac.title)
            } else if presentation.selectedSection == .devices, let syncContent {
                syncContent.navigationTitle(ModernPage.devices.title)
            } else {
                overviewContent
            }
        }
        .onReceive(liveWork?.$diskSpace.dropFirst().eraseToAnyPublisher() ?? Empty<DiskSpace?, Never>().eraseToAnyPublisher()) {
            store.updateObservedDiskSpace($0)
        }
        .onChange(of: store.isDeleting) { _, active in
            if active, !presentation.isReviewingCleanup { presentation.showsCleanupProgress = true }
        }
        .onAppear {
            if store.cleanupProgress != nil || store.resultMessage != nil {
                presentation.showsCleanupProgress = true
            }
        }
        .sheet(isPresented: $presentation.showsCleanupProgress) {
            CleanupProgressView(store: store) { presentation.showsCleanupProgress = false }
        }
    }

    private func navigationItem(_ title: String, symbol: String, section: OverviewSection) -> some View {
        Group {
            if interfaceStyle == .modern {
                // Coloured squares, as in System Settings.
                Label {
                    Text(LocalizedStringKey(title), bundle: AppLanguage.resourceBundle)
                } icon: {
                    ModernIcon(symbol: Self.modernSymbol(for: section), color: Self.modernColor(for: section), size: 20)
                }
            } else {
                Label(LocalizedStringKey(title), systemImage: symbol)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { focus(section) }
            .accessibilityAction { focus(section) }
    }

    private static func modernSymbol(for section: OverviewSection) -> String {
        switch section {
        case .overview: "square.grid.2x2.fill"
        case .thisMac: ModernPage.thisMac.symbol
        case .devices: ModernPage.devices.symbol
        case .resources: "chart.pie.fill"
        case .clean: ModernPage.clean.symbol
        case .branches: "arrow.triangle.branch"
        case .settings: "gearshape.fill"
        }
    }

    private static func modernColor(for section: OverviewSection) -> Color {
        switch section {
        case .overview: Color(nsColor: .systemBlue)
        case .thisMac: ModernPalette.cpu
        case .devices: Self.color(for: .devices)
        case .resources: Color(nsColor: .systemPurple)
        case .clean: Self.color(for: .clean)
        case .branches: Color(nsColor: .systemGreen)
        case .settings: Color(nsColor: .systemGray)
        }
    }

    private func focus(_ section: OverviewSection) {
        if section == .settings, settingsContent != nil { openSettings() }
        else { presentation.focus(section) }
    }

    /// Modern gives each sidebar item a page of its own, so the sidebar
    /// always names what is on screen.
    @ViewBuilder
    private var modernPage: some View {
        switch presentation.modernPage {
        case .overview:
            ModernOverviewPage(store: store, liveWork: liveWork, usageStore: usageStore, settings: settings,
                               presentation: presentation)
                .navigationTitle("Overview")
        case .usage:
            ModernUsagePage(usageStore: usageStore, settings: settings, localToolStatus: localToolStatus,
                            connectContent: connectContent, liveWork: liveWork,
                            openBranches: { presentation.open(.branches) }, openSettings: openSettings)
                .navigationTitle("Usage")
        case .thisMac:
            ThisMacPage(liveWork: liveWork)
                .background(ModernPalette.page)
                .environment(\.interfaceStyle, .modern)
                .navigationTitle(ModernPage.thisMac.title)
        case .clean:
            CleanPage(store: store, presentation: presentation)
                .navigationTitle(Text("Clean", bundle: AppLanguage.resourceBundle))
        case .memory, .storage:
            ModernResourcePage(resource: presentation.modernPage == .memory ? .memory : .storage,
                               store: store, liveWork: liveWork, presentation: presentation)
                .id(presentation.modernPage)
                .navigationTitle(presentation.modernPage.title)
        case .devices:
            (syncContent ?? AnyView(EmptyView()))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ModernPalette.page)
            .navigationTitle("iPhone & Watch")
        case .branches, .worktrees:
            BranchesRootView(store: store, liveWork: liveWork, agentStore: agentStore, presentation: presentation,
                             mode: .worktrees, workKind: presentation.modernPage == .branches ? .branches : .worktrees)
                .id(presentation.modernPage)
                .navigationTitle(presentation.modernPage.title)
        }
    }

    private var overviewContent: some View {
        BranchesRootView(store: store, liveWork: liveWork, agentStore: agentStore,
                         presentation: presentation, overviewHeader: AnyView(overviewHeader))
        .navigationTitle("Overview")
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let usageStore, let settings {
                MainUsageOverview(store: usageStore, settings: settings, openSettings: openSettings)
            }
            if let liveWork {
                CPUOverviewSummary(monitor: liveWork.cpu) { presentation.focus(.thisMac) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 16)
    }
}

@available(macOS 14.0, *)
private struct MainUsageOverview: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    var openSettings: () -> Void
    @State private var cardContentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI tools usage").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Manage Tools…", action: openSettings).controlSize(.small)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        let snapshots = settings.ordered(store.visibleSnapshots)
        if !snapshots.isEmpty {
            if case .stale = store.state {
                Label("Showing the last reading. Reconnecting…", systemImage: "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(toolIDs(in: snapshots)) { toolID in
                    MainQuotaTool(snapshots: snapshots.filter { $0.toolID == toolID }, contentHeight: cardContentHeight)
                }
            }
            .onPreferenceChange(UsageToolContentHeight.self) { height in
                if abs(cardContentHeight - height) > 0.5 { cardContentHeight = height }
            }
        } else {
            HStack(spacing: 10) {
                if case .connecting = store.state { ProgressView().controlSize(.small) }
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
            }
        }
    }

    private func toolIDs(in snapshots: [QuotaSnapshot]) -> [AIToolID] {
        var seen: Set<AIToolID> = []
        return snapshots.map(\.toolID).filter { seen.insert($0).inserted }
    }

    private var emptyText: String {
        switch store.state {
        case .connecting: "Connecting to your AI tools…"
        case .signedOut: UsageState.connectGuidance
        case .unavailable(let message): message
        default: store.visibleSnapshots.isEmpty
            ? "No usage readings yet. Connect a tool in Settings."
            : "All usage readings are hidden. Choose what appears in Manage Tools."
        }
    }
}

private struct UsageToolContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@available(macOS 14.0, *)
private struct MainQuotaTool: View {
    let snapshots: [QuotaSnapshot]
    let contentHeight: CGFloat

    var body: some View {
        if let first = snapshots.first {
            let tool = AIToolDescriptor.descriptor(for: first)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: tool.systemImage)
                            .frame(width: 16).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.callout.weight(.semibold)).lineLimit(1)
                            if snapshots.count == 1 {
                                Text(first.displayName).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).help(first.displayName)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    ForEach(snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 5) {
                            if snapshots.count > 1 {
                                Text(snapshot.displayName).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).help(snapshot.displayName)
                            }
                            window(snapshot.primaryWindow, snapshot: snapshot, toolName: tool.name)
                            if let secondary = snapshot.secondaryWindow {
                                window(secondary, snapshot: snapshot, toolName: tool.name)
                            }
                        }
                    }
                }
                .padding(4)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: UsageToolContentHeight.self,
                                               value: geometry.size.height.rounded(.up))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: contentHeight, alignment: .topLeading)
            }
        }
    }

    private func window(_ window: QuotaWindowSnapshot, snapshot: QuotaSnapshot, toolName: String) -> some View {
        HStack(spacing: 8) {
            Text(window.typeTag).font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            ProgressView(value: window.remainingPercent, total: 100)
                .controlSize(.small)
                .tint(QuotaSeverity(remainingPercent: window.remainingPercent).color)
                .accessibilityLabel("\(toolName) \(snapshot.displayName) \(window.typeTag) remaining")
            Text("\(Int(window.remainingPercent))% left")
                .font(.caption.monospacedDigit()).frame(width: 55, alignment: .trailing)
        }
    }
}

/// Modern's Usage page: every AI tool's limits. Edit works on the same
/// cards: switches show or hide, cards drag into order, and tools not set
/// up yet are listed with what they need. Detect and Connect sit beside Done.
@available(macOS 14.0, *)
private struct ModernUsagePage: View {
    var usageStore: UsageStore?
    var settings: HUDSettings?
    var localToolStatus: LocalToolStatusRegistry?
    var connectContent: AnyView?
    var liveWork: LiveWorkMonitor?
    var openBranches: (() -> Void)?
    let openSettings: () -> Void
    @State private var editing = false
    @State private var detectionRevision = 0
    @State private var detecting = false
    @State private var connecting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let usageStore, let settings {
                    ModernUsageBoard(store: usageStore, settings: settings, localToolStatus: localToolStatus,
                                     editing: editing, liveWork: liveWork, openBranches: openBranches,
                                     detectionRevision: detectionRevision)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ModernPalette.page)
        .environment(\.interfaceStyle, .modern)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            detectionRevision += 1
        }
        .sheet(isPresented: $connecting) {
            VStack(spacing: 0) {
                HStack {
                    Text("Connect AI Tool").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { connecting = false }.keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                connectContent
            }
            .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if editing {
                    Text("Show or hide installed tools and their limits, or drag cards to reorder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if editing {
                Button {
                    guard let usageStore, !detecting else { return }
                    Task {
                        detectionRevision += 1
                        detecting = true
                        await usageStore.refresh()
                        detecting = false
                    }
                } label: {
                    if detecting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Detecting…") }
                    } else {
                        Label("Detect", systemImage: "magnifyingglass")
                    }
                }
                .disabled(detecting)
                .help("Look again for AI tools on this Mac")
                if connectContent != nil {
                    Button("Connect AI Tool…", systemImage: "plus") { connecting = true }
                        .help("Pair a remote AI tool with a one-time code")
                }
                Button("Done") { withAnimation(.snappy(duration: 0.2)) { editing = false } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Edit") { withAnimation(.snappy(duration: 0.2)) { editing = true } }
                    .help("Show or hide tools and limits, reorder them, and add tools")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 4)
    }
}

/// Modern's Overview: one card for each AI tool and for each page, all the
/// same size, each with one figure. The detail is a click away.
@available(macOS 14.0, *)
private struct ModernOverviewPage: View {
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .headline) private var minimumResourceCardWidth: CGFloat = 196
    @ObservedObject var store: BranchesStore
    var liveWork: LiveWorkMonitor?
    var usageStore: UsageStore?
    var settings: HUDSettings?
    let presentation: BranchesPaperweightPresentation

    var body: some View {
        let board = BranchesBoard.make(snapshot: store.snapshot, now: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Overview")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
                if let usageStore, let settings {
                    ModernToolCards(store: usageStore, settings: settings) {
                        presentation.open(.usage)
                    }
                }
                sectionTitle("Running")
                if let liveWork {
                    CPUOverviewSummary(monitor: liveWork.cpu) { presentation.open(.thisMac) }
                }
                ViewThatFits(in: .horizontal) {
                    Grid(horizontalSpacing: 14) {
                        GridRow(alignment: .top) {
                            resourceCards
                        }
                    }
                    .frame(minWidth: minimumResourceCardWidth * 2 + 14,
                           idealWidth: minimumResourceCardWidth * 2 + 14, maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) { resourceCards }
                }
                Grid(horizontalSpacing: 14) {
                    GridRow {
                        workCard(.branches, board: board.only(.branches))
                        workCard(.worktrees, board: board.only(.worktrees))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ModernPalette.page)
        .environment(\.interfaceStyle, .modern)
    }

    @ViewBuilder private var resourceCards: some View {
        if let liveWork {
            ModernMemorySummary(monitor: liveWork, store: store) { presentation.open(.memory) }
        }
        ModernStorageSummary(store: store, history: liveWork?.storageHistory) { presentation.open(.storage) }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title), bundle: AppLanguage.resourceBundle)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 4)
            .padding(.top, 10)
    }

    /// What needs you first: work that needs a look, then what can go.
    private func workCard(_ page: ModernPage, board: BranchesBoard) -> some View {
        let needsLook = board.needsLookCount
        var caption: [String] = []
        if !board.running.isEmpty { caption.append(AppLanguage.format("%ld running", locale: locale, board.running.count)) }
        if !board.safeToClear.isEmpty { caption.append(AppLanguage.format("%ld safe to clear", locale: locale, board.safeToClear.count)) }
        return ModernSummaryCard(
            page: page,
            value: "\(needsLook)",
            unit: needsLook == 1 ? "needs a look" : "need a look",
            caption: caption.isEmpty ? AppLanguage.text("Nothing else to do", locale: locale) : caption.joined(separator: " · "),
            open: { presentation.open(page) }
        ) { EmptyView() }
    }
}

/// Every AI tool with a reading in one card that opens Usage: what's left
/// of the limit closest to running out as its figure, then a row for each
/// tool with a bar for each window of its tightest limit. Tools that can't
/// show usage are left to the Usage page.
@available(macOS 14.0, *)
private struct ModernToolCards: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    let open: () -> Void

    private struct ToolEntry: Identifiable {
        let tool: AIToolID
        /// Its tightest limit.
        let snapshot: QuotaSnapshot
        let others: Int
        var credits: [ResetCredit] = []
        var id: AIToolID { tool }
    }

    var body: some View {
        let entries: [ToolEntry] = ModernToolList.readingEntries(settings.ordered(store.visibleSnapshots))
            .compactMap { entry in
                guard let tightest = entry.limits.min(by: { tightness($0) < tightness($1) }) else { return nil }
                return ToolEntry(tool: entry.id, snapshot: tightest, others: entry.limits.count - 1,
                                 credits: entry.limits.availableResets())
            }
        VStack(alignment: .leading, spacing: 14) {
            Text("AI tools")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
                .padding(.top, 10)
            Button(action: open) {
                ModernCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            ModernIcon(symbol: ModernPage.usage.symbol, color: MainRootView.color(for: .usage), size: 22)
                            Text(LocalizedStringKey(ModernPage.usage.title), bundle: AppLanguage.resourceBundle).font(.headline)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        if let lowest = entries.min(by: { tightness($0.snapshot) < tightness($1.snapshot) }) {
                            figure(tool: lowest.tool, snapshot: lowest.snapshot, toolCount: entries.count)
                            VStack(spacing: 0) {
                                ForEach(entries) { row($0) }
                            }
                        } else {
                            Text("No usage readings yet. Choose Edit on the Usage page to find or connect tools.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .contentShape(RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ModernPage.usage.title)
            .accessibilityHint("Opens Usage")
        }
    }

    private func tightness(_ snapshot: QuotaSnapshot) -> Double {
        min(snapshot.remainingPercent, snapshot.secondaryWindow?.remainingPercent ?? 100)
    }

    /// The window of a limit with the least left.
    private func tightestWindow(_ snapshot: QuotaSnapshot) -> QuotaWindowSnapshot {
        guard let secondary = snapshot.secondaryWindow,
              secondary.remainingPercent < snapshot.primaryWindow.remainingPercent else { return snapshot.primaryWindow }
        return secondary
    }

    /// The limit closest to running out, across every tool: what's left,
    /// which limit and window it is, when it resets, and why it's the one
    /// shown.
    private func figure(tool: AIToolID, snapshot: QuotaSnapshot, toolCount: Int) -> some View {
        let window = tightestWindow(snapshot)
        let severity = QuotaSeverity(remainingPercent: window.remainingPercent)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(severity == .low || severity == .critical ? Color(nsColor: .systemRed) : Color.primary)
                    .contentTransition(.numericText())
                Text("left").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            Text("\(AIToolDescriptor.descriptor(for: tool).name) · \(snapshot.displayName) · \(window.limitName)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text([
                    ResetMomentText.sentence(window.resetAt, now: context.date)
                        + (ResetMomentText.countdown(window.resetAt, now: context.date).map { ", in \($0)" } ?? ""),
                    toolCount > 1 ? "the lowest of your \(toolCount) AI tools" : nil,
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 4)
    }

    private func row(_ entry: ToolEntry) -> some View {
        let tool = AIToolDescriptor.descriptor(for: entry.tool)
        let caption = ([entry.snapshot.displayName + (entry.others > 0 ? " · +\(entry.others) more" : "")]
            + [ResetCreditText.count(entry.credits)].compactMap { $0 }).joined(separator: " · ")
        return HStack(alignment: .center, spacing: 12) {
            AIToolIcon(tool: tool, size: 15)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            VStack(spacing: 6) {
                ModernQuotaBar(window: entry.snapshot.primaryWindow)
                if let secondary = entry.snapshot.secondaryWindow {
                    ModernQuotaBar(window: secondary)
                }
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dashboard card with one reading and its supporting chart or summary.
@available(macOS 14.0, *)
private struct ModernSummaryCard<Detail: View>: View {
    let page: ModernPage
    var title: String? = nil
    let value: String
    var unit: String? = nil
    let caption: String
    var cpuHistory: SystemCPUMonitor.History? = nil
    var resourceHistory: ResourceTrendHistory? = nil
    let open: () -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        Button(action: open) {
            ModernCard {
                if let cpuHistory {
                    let trend = CPUTrendChart(samples: cpuHistory, plotHeight: 108)
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                reading.fixedSize(horizontal: true, vertical: false)
                                trend.frame(minWidth: 210, maxWidth: 640)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                reading
                                trend
                            }
                        }
                        detail()
                    }
                } else if let resourceHistory {
                    let trend = ResourceTrendChart(history: resourceHistory, resource: page == .memory ? .memory : .storage,
                                                   compact: true, plotHeight: 68)
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        amount
                        Text(caption).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        trend
                        detail()
                    }
                } else {
                    stacked
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(page.title)")
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            reading
            detail()
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ModernIcon(symbol: page.symbol, color: MainRootView.color(for: page), size: 22)
            Text(LocalizedStringKey(title ?? page.title), bundle: AppLanguage.resourceBundle).font(.headline)
            Spacer(minLength: 4)
            if resourceHistory != nil {
                Text("10 min", bundle: AppLanguage.resourceBundle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            chevron
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 2) {
            amount
            Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(LocalizedStringKey(unit), bundle: AppLanguage.resourceBundle).font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

@available(macOS 14.0, *)
private struct CPUOverviewSummary: View {
    @Environment(\.locale) private var locale
    @ObservedObject var monitor: SystemCPUMonitor
    let open: () -> Void

    var body: some View {
        ModernSummaryCard(page: .thisMac,
                          value: monitor.usage.map { LiveWorkText.percent($0.busy) } ?? "–",
                          unit: "in use",
                          caption: AppLanguage.format("%ld logical cores", locale: locale, ProcessInfo.processInfo.activeProcessorCount),
                          cpuHistory: monitor.samples,
                          open: open) {
            CPUTimeBreakdown(usage: monitor.usage)
        }
    }
}

@available(macOS 14.0, *)
private struct ModernMemorySummary: View {
    @Environment(\.locale) private var locale
    @ObservedObject var monitor: LiveWorkMonitor
    @ObservedObject var store: BranchesStore
    let open: () -> Void

    var body: some View {
        let board = BranchesBoard.make(snapshot: store.snapshot, now: Date())
        let memory = PaperweightData.memory(summary: monitor.summary, running: board.running,
                                            systemUsage: monitor.memoryUsage)
        ModernSummaryCard(
            page: .memory,
            value: memory.freeBytes == nil ? "–" : memory.id.formatBytes(memory.usedBytes),
            unit: memory.freeBytes == nil ? nil : "in use",
            caption: monitor.memoryUsage?.breakdown(locale: locale)
                ?? AppLanguage.text("Memory unavailable", locale: locale),
            resourceHistory: monitor.memoryHistory,
            open: open
        ) {
            CapacityBar(segments: ModernResourceCard.segments(memory), capacity: memory.capacityBytes,
                        height: ProportionalBar.thinHeight, gap: 0)
        }
    }
}

@available(macOS 14.0, *)
private struct ModernStorageSummary: View {
    @Environment(\.locale) private var locale
    @ObservedObject var store: BranchesStore
    let history: ResourceTrendHistory?
    let open: () -> Void

    var body: some View {
        let now = Date()
        let board = BranchesBoard.make(snapshot: store.snapshot, now: now)
        let storage = PaperweightData.storage(disk: store.diskSpace, board: board, toolStorage: store.toolStorage,
                                              isMeasuring: store.isMeasuringToolStorage || !store.hasMeasuredToolStorage)
        let freeable = ClearSelection(items: board.safeToClear, now: now).bytes(from: board.safeToClear)
        let disk = store.diskSpace
        ModernSummaryCard(
            page: .storage,
            value: disk.map { RailResourceText.freeSpace($0.availableBytes) } ?? "–",
            unit: disk == nil ? nil : "free",
            caption: freeable > 0 ? AppLanguage.format("About %@ can be cleared", locale: locale, BoardText.bytes(freeable))
                : disk.map { AppLanguage.format("%@ of %@ used", locale: locale, LiveWorkText.percent($0.usedShare()), BoardText.bytes($0.totalBytes)) }
                    ?? AppLanguage.text("Disk space unavailable", locale: locale),
            resourceHistory: history,
            open: open
        ) {
            CapacityBar(segments: ModernResourceCard.segments(storage), capacity: storage.capacityBytes,
                        height: ProportionalBar.thinHeight, gap: 0)
        }
    }
}

/// One usage limit as a bar: the window, a bar of what's left, the
/// percentage and when it resets.
@available(macOS 14.0, *)
struct ModernQuotaBar: View {
    @Environment(\.usageCardColumns) private var columns
    let window: QuotaWindowSnapshot
    /// Off where the reset is spelled out on a line of its own.
    var showsReset = true

    var body: some View {
        let severity = QuotaSeverity(remainingPercent: window.remainingPercent)
        // Classic's critical red is too dark to read as text on a dark card.
        let tint = severity == .critical ? Color(nsColor: .systemRed) : severity.color
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: columns?.spacing ?? 8) {
                Text(window.typeTag)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: columns?.markerWidth ?? 28, alignment: columns == nil ? .leading : .center)
                GeometryReader { geometry in
                    Capsule().fill(tint.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint.gradient)
                                .frame(width: max(geometry.size.height,
                                                  geometry.size.width * min(1, max(0, window.remainingPercent / 100))))
                        }
                }
                .frame(height: 8)
                .frame(minWidth: 60)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .frame(width: 44, alignment: .trailing)
                if showsReset {
                    // When it resets, not just how long: "Resets 3:40 PM".
                    Text(ResetMomentText.sentence(window.resetAt, now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 150, alignment: .leading)
                        .help(ResetMomentText.countdown(window.resetAt, now: context.date).map { "In \($0)" } ?? "")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.typeTag) window")
            .accessibilityValue(showsReset
                ? "\(Int(window.remainingPercent.rounded())) percent left, \(ResetMomentText.sentence(window.resetAt, now: context.date))"
                : "\(Int(window.remainingPercent.rounded())) percent left")
        }
    }
}

extension QuotaWindowSnapshot {
    /// The window in words: "5-hour limit", "weekly limit".
    var limitName: String {
        guard let minutes = windowDurationMinutes, minutes > 0 else { return "limit" }
        switch minutes {
        case 1_440: return "daily limit"
        case 10_080: return "weekly limit"
        case 40_320...44_640: return "monthly limit"
        default:
            if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day limit" }
            if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour limit" }
            return "\(minutes)-minute limit"
        }
    }
}
