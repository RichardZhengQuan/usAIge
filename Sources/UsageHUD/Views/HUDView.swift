import AppKit
import SwiftUI

enum RailDetailID: Hashable {
    case limit(String)
    case tool(AIToolID)
    case cpu
    case liveWork
    case storage
}

struct RailQuotaRow: Identifiable, Equatable {
    let id: RailDetailID
    let snapshot: QuotaSnapshot
    let otherLimits: [QuotaSnapshot]

    init(snapshot: QuotaSnapshot, id: RailDetailID? = nil, otherLimits: [QuotaSnapshot] = []) {
        self.id = id ?? .limit(snapshot.id)
        self.snapshot = snapshot
        self.otherLimits = otherLimits
    }

    /// Modern keeps a row for the tool even when its tightest limit changes.
    static func rows(for snapshots: [QuotaSnapshot], style: InterfaceStyle) -> [Self] {
        guard style == .modern else { return snapshots.map { Self(snapshot: $0) } }
        var order: [AIToolID] = []
        var byTool: [AIToolID: [QuotaSnapshot]] = [:]
        for snapshot in snapshots {
            if byTool[snapshot.toolID] == nil { order.append(snapshot.toolID) }
            byTool[snapshot.toolID, default: []].append(snapshot)
        }
        func tightness(_ snapshot: QuotaSnapshot) -> Double {
            min(snapshot.remainingPercent, snapshot.secondaryWindow?.remainingPercent ?? 100)
        }
        return order.compactMap { tool in
            guard let limits = byTool[tool],
                  let tightest = limits.min(by: { tightness($0) < tightness($1) }) else { return nil }
            return Self(snapshot: tightest, id: .tool(tool), otherLimits: limits.filter { $0.id != tightest.id })
        }
    }
}

@available(macOS 14.0, *)
struct HUDView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.hudPreviewsHover) private var previewsHover
    @ObservedObject var store: UsageStore
    @ObservedObject var agentStore: CodexAgentStore
    @ObservedObject var settings: HUDSettings
    @ObservedObject var updateController: UpdateController
    let openTool: (AIToolDescriptor) -> Void
    let openCodex: () -> Void
    let openSettings: () -> Void
    let resizePanel: (CGSize) -> Void
    @ObservedObject var screenState: PanelScreenState
    var quotaDetail: QuotaDetailPanelController? = nil
    var liveWork: LiveWorkMonitor? = nil
    var openBranches: () -> Void = {}
    var openResourcePaperweight: ((PaperweightID) -> Void)? = nil
    var openThisMac: () -> Void = {}
    @AppStorage(InterfaceStyle.defaultsKey) private var interfaceStyle = InterfaceStyle.standard
    @State private var isPanelHovered = false
    @State private var labelWidth: CGFloat = 0
    @State private var detailHoveredRowIDs: Set<RailDetailID> = []
    @State private var isRefreshing = false
    @State private var sailingShakeID = 0
    @AppStorage(CruiseWeather.defaultsKey) private var sailingWeatherRaw = CruiseWeather.automatic.rawValue
    @AppStorage(PaperweightShipPreferences.storageKey) private var sailingShipRaw = PaperweightShipKind.galleon.rawValue

    private var sailingWeather: CruiseWeather {
        CruiseWeather(rawValue: sailingWeatherRaw) ?? .automatic
    }
    private var sailingShip: PaperweightShipKind { PaperweightShipKind(rawValue: sailingShipRaw) ?? .galleon }

    private var availableSnapshots: [QuotaSnapshot] {
        switch store.state {
        case let .current(values), let .stale(values, _): values
        default: []
        }
    }

    private var snapshots: [QuotaSnapshot] {
        settings.ordered(availableSnapshots)
    }

    /// The rail grows to show every visible tool; only when the display is
    /// too short for them all does it fall back to scrolling.
    /// Modern runs the rail the full height of the display, flush against
    /// its side, like a sidebar.
    private var isEdgeRail: Bool { interfaceStyle == .modern }

    private var desiredSize: CGSize {
        let availableWidth = screenState.visibleWidth - (isEdgeRail ? 0 : 2 * PanelPositioner.inset)
        let width = HUDMetrics.railWidth(for: settings.textSize, labelWidth: labelWidth,
                                         maximumWidth: availableWidth / settings.scale)
        if isEdgeRail {
            return CGSize(
                width: width,
                height: HUDMetrics.edgeRailHeight(visibleHeight: screenState.screenHeight, scale: settings.scale)
            )
        }
        let maximumHeight = HUDMetrics.maximumRailHeight(visibleHeight: screenState.visibleHeight, scale: settings.scale)
        let height: CGFloat = switch store.state {
        case .current, .stale:
            HUDMetrics.railHeight(rowCount: snapshots.count, maximumHeight: maximumHeight,
                                  showsWorkTile: liveWork != nil, textSize: settings.textSize)
        default:
            min(maximumHeight, HUDMetrics.messageSize.height + (liveWork == nil ? 0 : HUDMetrics.workTileHeight * settings.textSize.factor + HUDMetrics.columnSpacing))
        }
        return CGSize(width: width, height: height)
    }

    private var scaledSize: CGSize {
        let size = HUDMetrics.scaledSize(desiredSize, scale: settings.scale)
        guard isEdgeRail else { return size }
        // AppKit rounds the panel frame to window points. Paint all of it even
        // when the user's scale produces a fractional content width.
        return CGSize(width: ceil(size.width), height: screenState.screenHeight)
    }

    private var hasCriticalQuota: Bool {
        snapshots.contains {
            QuotaSeverity(remainingPercent: $0.remainingPercent).showsScaryGlow
                || QuotaSeverity(
                    remainingPercent: $0.secondaryWindow?.remainingPercent ?? 100
                ).showsScaryGlow
        }
    }

    private var currentLimitSeverity: QuotaSeverity {
        let remainingPercentages = snapshots.flatMap { snapshot in
            [snapshot.remainingPercent, snapshot.secondaryWindow?.remainingPercent]
                .compactMap { $0 }
        }
        return QuotaSeverity(remainingPercent: remainingPercentages.min() ?? 100)
    }

    private var showsStatusSurface: Bool {
        switch store.state {
        case .current, .stale: false
        default: true
        }
    }

    var body: some View {
        content
            // A full-height rail's glass runs behind the menu bar and the
            // Dock; its content keeps clear of them inside the glass.
            .padding(.top, isEdgeRail ? edgeInset(screenState.safeTop) : 10)
            .padding(.bottom, isEdgeRail ? edgeInset(screenState.safeBottom) : 10)
            .padding(.horizontal, HUDMetrics.horizontalInset)
            .environment(\.hudTextSize, settings.textSize)
            .onPreferenceChange(HUDLabelWidthKey.self) { width in
                MainActor.assumeIsolated { labelWidth = width }
            }
            .frame(width: desiredSize.width, height: desiredSize.height)
            .background {
                if !isEdgeRail { panelSurface }
            }
            .overlay {
                ZStack {
                    if !isEdgeRail {
                        edgeLine.opacity(isPanelHovered || !detailHoveredRowIDs.isEmpty ? 1 : 0)
                    }
                    if hasCriticalQuota && isPanelHovered {
                        // The window ends at the rail's edge, so anything drawn
                        // past its rounded corners shows as a square pocket.
                        panelShape
                            .stroke(Color.red.opacity(0.86), lineWidth: 1.5)
                            .shadow(color: .red, radius: 8)
                            .shadow(color: .red.opacity(0.8), radius: 18)
                            .clipShape(panelShape)
                            .accessibilityHidden(true)
                    }
                }
            }
            .contentShape(panelShape)
            .contextMenu {
                if isEdgeRail {
                    Button("Use Classic Style") { interfaceStyle = .classic }
                } else {
                    Picker("Sailing weather", selection: $sailingWeatherRaw) {
                        ForEach(CruiseWeather.allCases) { weather in
                            Label(weather.title, systemImage: weather.symbol).tag(weather.rawValue)
                        }
                    }
                    Divider()
                    Button("Shake the sea", systemImage: "water.waves") { sailingShakeID += 1 }
                        .disabled(reduceMotion)
                    Divider()
                    Button("Use Modern Style") { interfaceStyle = .modern }
                }
            }
            .onHover { isHovered in
                isPanelHovered = isHovered
                guard isHovered else { return }
                Task { await store.refreshIfNeeded(maximumAge: 5) }
            }
            .animation(.easeOut(duration: 0.18), value: isPanelHovered)
            // A full-height rail's opacity is its background's; its rings
            // and text always stay fully visible.
            .opacity(isEdgeRail ? 1 : HUDMetrics.contentOpacity(
                configured: settings.opacity,
                isHovered: isPanelHovered,
                isCritical: hasCriticalQuota,
                forceVisible: showsStatusSurface
            ))
            .scaleEffect(settings.scale)
            .frame(width: scaledSize.width, height: scaledSize.height)
            .background { if isEdgeRail { panelSurface } }
            .overlay { if isEdgeRail { edgeLine.allowsHitTesting(false) } }
            .task(id: availableSnapshots.map(\.id)) {
                settings.registerBuckets(availableSnapshots)
            }
            .onAppear {
                if previewsHover { isPanelHovered = true }
                resizePanel(scaledSize)
            }
            // The footer stays hidden until the pointer is over the rail, which
            // VoiceOver never reports, so its actions live on the rail too.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("usAIge")
            .accessibilityValue(isRefreshing ? "Refreshing" : "")
            .accessibilityAction(named: "Refresh usage and session status") { refreshAll() }
            .accessibilityAction(named: "Open Settings") { openSettings() }
            .accessibilityAction(named: "Open Branches and Worktrees") { openBranches() }
            .onChange(of: scaledSize) { _, size in resizePanel(size) }
            .onChange(of: railRows) { _, rows in quotaDetail?.update(rows) }
    }

    /// Unscaled room for a bar the system draws over the rail, plus a margin.
    private func edgeInset(_ systemInset: CGFloat) -> CGFloat {
        systemInset / CGFloat(max(settings.scale, 0.1)) + HUDMetrics.edgeRailSafeArea
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isEdgeRail ? 0 : 18, style: .continuous)
    }

    /// A floating rail is outlined all round; a full-height rail only on the
    /// side facing the windows, as a sidebar is.
    @ViewBuilder
    private var edgeLine: some View {
        if isEdgeRail {
            HStack(spacing: 0) {
                if screenState.railEdge == .right { Rectangle().fill(.separator).frame(width: 0.5) }
                Spacer(minLength: 0)
                if screenState.railEdge != .right { Rectangle().fill(.separator).frame(width: 0.5) }
            }
        } else {
            panelShape.stroke(.separator, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var panelSurface: some View {
        ZStack {
            if isEdgeRail {
                HUDGlassSurface(severity: currentLimitSeverity, isActive: true, cornerRadius: 0, isProminent: true)
                    .opacity(reduceTransparency ? 0 : settings.opacity)
                Color(nsColor: .windowBackgroundColor)
                    .opacity(reduceTransparency ? 1 : settings.opacity)
            } else {
                UsageAtmosphereBackground(compact: true,
                                          weather: sailingWeather, ship: sailingShip,
                                          command: sailingShakeID > 0 ? PaperweightSceneCommand(id: sailingShakeID, kind: .shake) : nil)
                if !reduceTransparency {
                    HUDGlassSurface(
                        severity: currentLimitSeverity,
                        isActive: HUDMetrics.glassSurfaceOpacity(
                            isHovered: isPanelHovered,
                            forceVisible: showsStatusSurface
                        ) > 0
                    )
                }
            }
        }
        .clipShape(panelShape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .current:
            quotaColumn(isStale: false)
        case .stale:
            quotaColumn(isStale: true)
        default:
            fittingColumn {
                statusContent
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch store.state {
        case .connecting:
            statusView(title: "Connecting")
        case .signedOut:
            messageView(
                title: "Signed Out",
                detail: UsageState.connectGuidance,
                symbol: "person.crop.circle.badge.xmark",
                actionTitle: "Open Codex",
                action: openCodex
            )
        case let .unavailable(message):
            messageView(
                title: "Offline",
                detail: message,
                symbol: "wifi.slash",
                actionTitle: "Open Codex",
                action: openCodex
            )
        case .empty:
            messageView(
                title: "No Data",
                detail: "No usage data was found.",
                symbol: "circle.dotted",
                actionTitle: "Retry"
            ) {
                Task { await store.refresh() }
            }
        case .current, .stale:
            EmptyView()
        }
    }

    private func quotaColumn(isStale: Bool) -> some View {
        VStack(spacing: HUDMetrics.columnSpacing) {
            fittingColumn {
                if snapshots.isEmpty {
                    Text("All usage hidden")
                        .font(.system(size: 11 * settings.textSize.factor))
                        .foregroundStyle(.secondary)
                        .hudRailLabel()
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: HUDMetrics.itemSpacing) { quotaRows }
                        .padding(.vertical, 4)
                        .opacity(isStale ? 0.62 : 1)
                }
            }
            Divider().opacity(isEdgeRail || isPanelHovered ? 0.45 : 0)
            footer(status: isStale ? .stale : .current)
        }
    }

    private func fittingColumn<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        let list = rows()
        let column = VStack(spacing: HUDMetrics.columnSpacing) {
            list
            resourceTiles
        }
        let rowHeight = HUDMetrics.rowHeight(for: settings.textSize)
        return ViewThatFits(in: .vertical) {
            column.fixedSize(horizontal: false, vertical: true)
            // Keep system readings in sight while a long tool list scrolls.
            VStack(spacing: HUDMetrics.columnSpacing) {
                ScrollView { list.frame(maxWidth: .infinity) }
                    .scrollIndicators(.never)
                    .frame(minHeight: rowHeight, idealHeight: rowHeight)
                resourceTiles.fixedSize(horizontal: false, vertical: true)
            }
            // On a short display at large scale, allow every tile to scroll.
            ScrollView {
                column.frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }

    private var railRows: [RailQuotaRow] {
        RailQuotaRow.rows(for: snapshots, style: interfaceStyle)
    }

    private var quotaRows: some View {
        ForEach(railRows) { row in
            let snapshot = row.snapshot
            QuotaRowView(
                snapshot: snapshot,
                otherLimits: row.otherLimits,
                agentPhase: agentStore.phase(for: snapshot.toolID),
                agentTaskID: agentStore.targetTask(for: snapshot.toolID)?.id,
                openTool: openTool,
                openAgentTask: { taskID in
                    agentStore.acknowledge(taskID: taskID)
                    // Codex can open the exact task; the other
                    // tools open to their own app.
                    if snapshot.toolID == .chatGPT {
                        AIToolLauncher.openCodexTask(id: taskID)
                    } else {
                        openTool(.descriptor(for: snapshot))
                    }
                },
                onDetailHoverChanged: { isHovered, rowFrame in
                    detailHoverChanged(row.id, inside: isHovered) {
                        quotaDetail?.show(row, rowFrame: rowFrame)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var resourceTiles: some View {
        if let liveWork {
            VStack(spacing: isEdgeRail ? HUDMetrics.itemSpacing : HUDMetrics.resourcePaperweightGap) {
                CPUTile(monitor: liveWork.cpu, open: openThisMac) { isHovered, frame in
                    detailHoverChanged(.cpu, inside: isHovered) {
                        quotaDetail?.showCPU(rowFrame: frame, monitor: liveWork.cpu)
                    }
                }
                LiveWorkTile(monitor: liveWork, open: { openPaperweight(.memory) }) { isHovered, frame in
                    detailHoverChanged(.liveWork, inside: isHovered) {
                        quotaDetail?.showLiveWork(rowFrame: frame, history: liveWork.memoryHistory)
                    }
                }
                StorageTile(monitor: liveWork, open: { openPaperweight(.storage) }) { isHovered, frame in
                    detailHoverChanged(.storage, inside: isHovered) {
                        quotaDetail?.showStorage(rowFrame: frame, disk: liveWork.diskSpace,
                                                 breakdown: StorageBreakdown.load(from: .standard), history: liveWork.storageHistory)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detailHoverChanged(_ id: RailDetailID, inside: Bool, show: () -> Void) {
        if inside {
            detailHoveredRowIDs.insert(id)
            show()
        } else {
            detailHoveredRowIDs.remove(id)
            quotaDetail?.pointerLeft(rowID: id)
        }
    }

    private func openPaperweight(_ paperweight: PaperweightID) {
        if let openResourcePaperweight { openResourcePaperweight(paperweight) }
        else { openBranches() }
    }

    private func footer(status: FooterStatus) -> some View {
        HStack(spacing: 6) {
            refreshButton
            switch status {
            case .stale:
                Image(systemName: "wifi.slash")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .help("Showing the last usage; the latest refresh failed")
                    .accessibilityLabel("Showing the last usage; the latest refresh failed")
            case .current:
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .help("Usage is current")
                    .accessibilityLabel("Usage is current")
            case .connecting:
                ProgressView()
                    .controlSize(.mini)
                    .help("Connecting to Codex")
                    .accessibilityLabel("Connecting to Codex")
            case .disconnected:
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .help("Codex is disconnected")
                    .accessibilityLabel("Codex is disconnected")
            }
            settingsLink
        }
        .padding(.horizontal, 3)
        .frame(height: 24)
        // The full-height rail always shows refresh, status and Settings.
        .opacity(showsStatusSurface || isEdgeRail ? 1 : HUDMetrics.controlOpacity(isHovered: isPanelHovered))
        .allowsHitTesting(showsStatusSurface || isEdgeRail || isPanelHovered)
    }

    private var refreshButton: some View {
        Button(action: refreshAll) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help(isRefreshing ? "Refreshing…" : "Refresh usage and session status")
        .accessibilityLabel("Refresh usage and session status")
        .accessibilityValue(isRefreshing ? "Refreshing" : "")
    }

    /// Refreshes usage and session lights together; the refresh control shows
    /// progress until both are back.
    private func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            async let usageRefresh: Void = store.refresh()
            async let agentRefresh: Void = agentStore.refresh()
            _ = await (usageRefresh, agentRefresh)
            isRefreshing = false
        }
    }

    private var settingsLink: some View {
        Button(action: openSettings) {
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

    private func statusView(title: String) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14))
                ProgressView().controlSize(.small)
            }
            .frame(width: 34, height: 34)
            Text(title)
                .font(.system(size: 11 * settings.textSize.factor, weight: .semibold))
                .lineLimit(1)
                .hudRailLabel()
            footer(status: .connecting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageView(
        title: String,
        detail: String,
        symbol: String,
        actionTitle: String,
        usesPrimaryAction: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 7) {
            if usesPrimaryAction {
                Button(action: action) {
                    messageHeader(title: title, symbol: symbol)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(actionTitle)
                .accessibilityLabel(title)
                .accessibilityHint(actionTitle)
            } else {
                messageHeader(title: title, symbol: symbol)
            }
            HStack(spacing: 5) {
                refreshButton
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Codex is disconnected")
                settingsLink
                if !usesPrimaryAction {
                    Button(action: action) {
                        Image(systemName: "arrow.up.forward")
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(actionTitle)
                    .accessibilityLabel(actionTitle)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(detail)
        .accessibilityValue(detail)
    }

    private func messageHeader(title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11 * settings.textSize.factor, weight: .semibold))
                .lineLimit(1)
                .hudRailLabel()
        }
    }

    private enum FooterStatus {
        case current
        case stale
        case connecting
        case disconnected
    }
}

@available(macOS 14.0, *)
struct HUDGlassSurface: View {
    let severity: QuotaSeverity
    let isActive: Bool
    var cornerRadius: CGFloat = 18
    /// Frosted rather than clear, for a surface that is always shown.
    var isProminent = false

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                let tint = severity.color
                    .mix(with: .white, by: 0.45)
                    .opacity(0.02)
                let glass = isActive
                    ? (isProminent ? Glass.regular : Glass.clear).tint(tint).interactive()
                    : Glass.identity

                Color.clear
                    .glassEffect(
                        glass,
                        in: .rect(cornerRadius: cornerRadius)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isProminent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
                    .opacity(isActive ? 1 : 0)
            }
        }
    }
}

/// Draws the rail as if the pointer were over it, for rendered previews of
/// the hovered state.
private struct HUDPreviewsHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hudTextSize: HUDTextSize {
        get { self[HUDTextSizeKey.self] }
        set { self[HUDTextSizeKey.self] = newValue }
    }

    var hudPreviewsHover: Bool {
        get { self[HUDPreviewsHoverKey.self] }
        set { self[HUDPreviewsHoverKey.self] = newValue }
    }
}

private struct HUDTextSizeKey: EnvironmentKey {
    static let defaultValue = HUDTextSize.standard
}

struct HUDLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Measure the complete label before the window constrains it, so the
    /// same text that is drawn determines the panel's required width.
    func hudRailLabel() -> some View {
        fixedSize(horizontal: true, vertical: false)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: HUDLabelWidthKey.self, value: geometry.size.width)
            })
    }
}

enum HUDMetrics {
    static let railWidth: CGFloat = 160
    static let horizontalInset: CGFloat = 14

    static func railWidth(for textSize: HUDTextSize, labelWidth: CGFloat = 0,
                          maximumWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let ideal = ceil(max(railWidth * textSize.factor, labelWidth + 2 * horizontalInset))
        return min(ideal, max(1, maximumWidth))
    }

    static let messageSize = CGSize(width: railWidth, height: 120)
    static let itemSpacing: CGFloat = 10
    static let quotaRowHeight: CGFloat = 102
    static let resourcePaperweightHeight: CGFloat = 35
    static let resourceReadoutHeight: CGFloat = 16
    static let resourceReadoutGap: CGFloat = 2
    static let resourceTileHeight: CGFloat = resourcePaperweightHeight + resourceReadoutHeight + resourceReadoutGap
    static let resourcePaperweightGap: CGFloat = 7
    static let workTileHeight: CGFloat = 3 * resourceTileHeight + 2 * resourcePaperweightGap
    static let columnSpacing: CGFloat = 7
    static let hoveredGlassOpacity = 1.0

    static let defaultMaximumRailHeight: CGFloat = 450
    static let screenInset: CGFloat = 32
    /// Room above the first ring and below the footer of a full-height rail.
    static let edgeRailSafeArea: CGFloat = 18

    /// A full-height rail's unscaled height: once the user's scale is
    /// applied it fills the display's visible height exactly.
    static func edgeRailHeight(visibleHeight: CGFloat, scale: Double) -> CGFloat {
        max(120, visibleHeight / CGFloat(max(scale, 0.1)))
    }

    static func railHeight(
        rowCount: Int,
        maximumHeight: CGFloat = defaultMaximumRailHeight,
        showsWorkTile: Bool = false,
        textSize: HUDTextSize = .standard
    ) -> CGFloat {
        let rowsHeight = CGFloat(rowCount) * rowHeight(for: textSize)
        let gapsHeight = CGFloat(max(0, rowCount - 1)) * itemSpacing
        let tileHeight = showsWorkTile ? ceil(workTileHeight * max(1, textSize.factor)) + columnSpacing : 0
        return min(max(120, maximumHeight), max(120, 65 + rowsHeight + gapsHeight + tileHeight))
    }

    static func rowHeight(for textSize: HUDTextSize) -> CGFloat {
        quotaRowHeight + ceil(34 * (textSize.factor - 1))
    }

    /// The tallest unscaled rail that still fits the display once the user's
    /// scale is applied, leaving a margin above and below.
    static func maximumRailHeight(visibleHeight: CGFloat, scale: Double) -> CGFloat {
        let usable = (visibleHeight - screenInset) / CGFloat(max(scale, 0.1))
        return max(120, usable)
    }

    static func scaledSize(_ size: CGSize, scale: Double) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func contentOpacity(
        configured: Double,
        isHovered: Bool,
        isCritical: Bool = false,
        forceVisible: Bool = false
    ) -> Double {
        if forceVisible { return 1 }
        if isHovered { return 1 }
        if isCritical { return max(configured, 0.92) }
        return configured
    }

    static func controlOpacity(isHovered: Bool) -> Double {
        isHovered ? 1 : 0
    }

    static func glassSurfaceOpacity(isHovered: Bool, forceVisible: Bool = false) -> Double {
        if forceVisible { return 1 }
        return isHovered ? hoveredGlassOpacity : 0
    }
}
