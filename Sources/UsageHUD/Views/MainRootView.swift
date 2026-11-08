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
    var updateController: UpdateController? = nil
    var openSettings: () -> Void

    private var selectedSection: Binding<OverviewSection?> {
        Binding(get: { presentation.selectedSection }, set: { section in
            guard let section else { return }
            focus(section)
        })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedSection) {
                Section("usAIge") {
                    navigationItem("Overview", symbol: "square.grid.2x2", section: .overview)
                        .tag(OverviewSection.overview)
                    navigationItem("Resources", symbol: "chart.pie", section: .resources)
                        .tag(OverviewSection.resources)
                    navigationItem("Branches & Worktrees", symbol: "arrow.triangle.branch", section: .branches)
                        .tag(OverviewSection.branches)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let updateController {
                        List {
                            SidebarUpdateReminderView(updateController: updateController) {
                                openSettings()
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(height: 64)
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
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { focus(section) }
            .accessibilityAction { focus(section) }
    }

    private func focus(_ section: OverviewSection) {
        if section == .settings, settingsContent != nil { openSettings() }
        else { presentation.focus(section) }
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
