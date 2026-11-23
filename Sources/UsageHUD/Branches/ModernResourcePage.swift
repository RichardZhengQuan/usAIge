import AppKit
import Combine
import SwiftUI

/// Modern's Memory or Storage page. One figure and one bar say how full this
/// Mac is; the categories under them say what is using it. Reviews, cleanup
/// progress and undo follow the main window's cleanup flow.
@available(macOS 14.0, *)
struct ModernResourcePage: View {
    let resource: PaperweightID
    @ObservedObject var store: BranchesStore
    var liveWork: LiveWorkMonitor?
    @ObservedObject var presentation: BranchesPaperweightPresentation
    @State private var summary: LiveWorkSummary
    @State private var memoryUsage: SystemMemoryUsage?
    @State private var expanded: Set<String> = []
    @State private var clearReview: ClearReviewRequest?
    @State private var singleReview: DeleteReviewRequest?
    @State private var memoryTab: String?
    private static let scrollSpace = "modernResourcePage"
    @State private var showsStorageReview = false
    @State private var storageCleanupStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(resource: PaperweightID, store: BranchesStore, liveWork: LiveWorkMonitor?,
         presentation: BranchesPaperweightPresentation) {
        self.resource = resource
        self.store = store
        self.liveWork = liveWork
        self.presentation = presentation
        _summary = State(initialValue: liveWork?.summary ?? LiveWorkSummary())
        _memoryUsage = State(initialValue: liveWork?.memoryUsage)
    }

    private var summaryUpdates: AnyPublisher<LiveWorkSummary, Never> {
        liveWork?.$summary.eraseToAnyPublisher() ?? Just(LiveWorkSummary()).eraseToAnyPublisher()
    }

    private var memoryUsageUpdates: AnyPublisher<SystemMemoryUsage?, Never> {
        liveWork?.$memoryUsage.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    var body: some View {
        let now = Date()
        let board = BranchesBoard.make(snapshot: store.snapshot, now: now)
        let picks = ClearSelection(items: board.safeToClear, now: now)
        let storage = PaperweightData.storage(
            disk: store.diskSpace, board: board, toolStorage: store.toolStorage,
            isMeasuring: store.isMeasuringToolStorage || !store.hasMeasuredToolStorage
        )
        let breakdown = StorageBreakdown(storage: storage, freeableBytes: picks.bytes(from: board.safeToClear), measuredAt: now)
        ScrollView {
            Group {
                if resource == .memory {
                    // The tabs scroll up with the page, then stay at the top.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        memoryContent(PaperweightData.memory(summary: summary, running: board.running, systemUsage: memoryUsage),
                                      board: board, now: now)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        storageContent(storage, board: board, picks: picks, now: now)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: Self.scrollSpace)
        .background(ModernPalette.page)
        .environment(\.interfaceStyle, .modern)
        .onReceive(summaryUpdates) { if $0 != summary { summary = $0 } }
        .onReceive(memoryUsageUpdates) { memoryUsage = $0 }
        .onChange(of: breakdown.map { [$0.worktreeBytes, $0.cacheBytes, $0.toolBytes, $0.freeableBytes] }) { _, _ in
            if let breakdown { store.recordStorageBreakdown(breakdown) }
        }
        .sheet(item: $singleReview, onDismiss: reviewDismissed) { request in
            DeleteReviewView(request: request) { chosen in
                singleReview = nil
                store.startDelete(chosen)
            } cancel: { singleReview = nil }
        }
        .sheet(isPresented: $showsStorageReview, onDismiss: storageReviewDismissed) {
            StorageCleanupReview(store: store) { chosen in
                guard store.startStorageCleanup(chosen) else { return false }
                storageCleanupStarted = true
                showsStorageReview = false
                return true
            } cancel: { showsStorageReview = false }
        }
        .sheet(item: $clearReview, onDismiss: reviewDismissed) { request in
            ClearReviewSheet(request: request, disk: store.diskSpace) { chosen in
                clearReview = nil
                expanded = []
                store.startDelete(chosen)
            } cancel: { clearReview = nil }
        }
    }

    // MARK: Memory

    @ViewBuilder
    private func memoryContent(_ memory: PaperweightConfiguration, board: BranchesBoard, now: Date) -> some View {
        // AI tools and dev servers, largest first. macOS and other apps
        // are already in the bar's key and have nothing to list.
        let layers = memory.layers
            .filter { $0.bytes > 0 && $0.id != PaperweightData.otherMemoryLayerID && $0.id != PaperweightData.swapLayerID }
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        VStack(alignment: .leading, spacing: 24) {
            heading("Memory")
            figureCard(
                value: memory.freeBytes == nil ? "–" : memory.id.formatBytes(memory.usedBytes),
                unit: memoryUsage == nil ? "" : "of \(memory.id.formatBytes(memory.capacityBytes)) in use",
                caption: memoryUsage.map { "RAM \($0.ramDescription)  ·  Swap \($0.swapDescription)" },
                configuration: memory
            )
            if memoryUsage == nil {
                ModernSection(title: "Not available") {
                    ModernNoteRow(text: "No memory reading is available.")
                }
            }
        }
        .padding(.bottom, 16)
        // One tab per tool or group, so the list shows one at a time.
        if let selected = layers.first(where: { $0.id == memoryTab }) ?? layers.first {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    let rows = PaperweightData.memoryRows(for: selected, in: memory, running: board.running)
                    ModernGroupBox {
                        if rows.measured.isEmpty, rows.sessionOnly.isEmpty {
                            ModernNoteRow(text: "The app and its helpers, outside repository folders.")
                        }
                        ForEach(rows.measured + rows.sessionOnly) { item in card(item, .running, now: now) }
                    }
                    if memory.layers.contains(where: { $0.id == PaperweightData.otherMemoryLayerID }) {
                        Text("Other apps and macOS are estimated from what the system reports in use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 4)
            } header: {
                ModernTabBar(
                    tabs: layers.map { layer in
                        ModernTab(id: layer.id, title: layer.title, detail: memory.amount(for: layer),
                                  icon: memoryTabIcon(layer))
                    },
                    selection: Binding(get: { selected.id }, set: { memoryTab = $0 })
                )
                .accessibilityLabel("Memory by tool")
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { PinnedHeaderBackground(space: Self.scrollSpace).padding(.horizontal, -24) }
            }
        }
    }

    /// A tool's own logo; dev servers get a server symbol.
    private func memoryTabIcon(_ layer: PaperweightLayer) -> AnyView {
        if layer.id.hasPrefix("tool-") {
            let tool = AIToolID(rawValue: String(layer.id.dropFirst("tool-".count)))
            return AnyView(AIToolIcon(tool: .descriptor(for: tool), size: 16))
        }
        return AnyView(Image(systemName: ModernPalette.symbol(for: layer))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ModernPalette.color(for: layer)))
    }

    // MARK: Storage

    @ViewBuilder
    private func storageContent(_ storage: PaperweightConfiguration, board: BranchesBoard,
                                picks: ClearSelection, now: Date) -> some View {
        let disk = store.diskSpace
        let freeable = picks.bytes(from: board.safeToClear)
        HStack(alignment: .center, spacing: 10) {
            heading("Storage")
            Spacer(minLength: 12)
            storageActions(board: board, now: now)
        }
        figureCard(
            value: disk.map { BoardText.bytes($0.availableBytes) } ?? "–",
            unit: disk.map { "free of \(BoardText.bytes($0.totalBytes))" } ?? "",
            caption: freeable > 0
                ? "About \(BoardText.bytes(freeable)) can be cleared from \(board.safeToClear.count) finished worktrees"
                    + (disk.map { ", leaving \(BoardText.bytes($0.availableBytes + freeable)) free." } ?? ".")
                : nil,
            configuration: storage
        )
        cleanupStatus()
        ModernSection(title: "Categories") {
            ModernNavigationRow(
                symbol: "folder.fill", color: ModernPalette.worktrees, title: "Worktrees",
                subtitle: "Folders AI tools work in, without their build cache",
                value: amount("wt", in: storage), action: { presentation.open(.worktrees) }
            )
            ModernNavigationRow(
                symbol: "hammer.fill", color: ModernPalette.buildCache, title: "Build cache",
                subtitle: "Inside worktree folders. A build makes it again.",
                value: amount("cache", in: storage), isExpanded: expanded.contains("cat|cache"),
                action: { toggle("cat|cache") }
            )
            if expanded.contains("cat|cache") { cacheRows(board, now: now) }
            ModernNavigationRow(
                symbol: "shippingbox.fill", color: ModernPalette.toolStorage, title: "Tool storage",
                subtitle: "AI tool history and caches. Shown only, never cleared.",
                value: amount("tool", in: storage), isExpanded: expanded.contains("cat|tool"),
                action: { toggle("cat|tool") }
            )
            if expanded.contains("cat|tool") { toolRows() }
            ModernNavigationRow(
                symbol: "macwindow", color: ModernPalette.system, title: "macOS and apps",
                subtitle: "The system, apps and your own files. usAIge doesn't clear these.",
                value: amount("other", in: storage)
            )
        }
        if !BranchesPresentation.restorable(store.snapshot.deletions, now: now).isEmpty {
            StorageRecoveryView(store: store) { presentation.showsCleanupProgress = true }
                .padding(.horizontal, 4)
        }
    }

    /// The page's one action: what clearing would free, and the way to it.
    /// The page's actions sit beside its title: read everything again, look
    /// for generated files, and review finished worktrees. Each review is a
    /// sheet, and each item is checked again before it goes.
    @ViewBuilder
    private func storageActions(board: BranchesBoard, now: Date) -> some View {
        let scanning = store.snapshot.activity != .idle
        Button(scanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise") {
            store.refresh()
            store.loadToolStorage(force: true)
            store.readDiskSpace()
        }
        .disabled(scanning || store.isDeleting)
        .help("Measure worktrees, build caches and tool storage again")
        Button("Generated Files…", systemImage: "hammer") { startStorageReview() }
            .disabled(store.isDeleting)
            .help("Find build output and dependencies a build makes again, and choose what goes")
        if !board.safeToClear.isEmpty {
            Button("Review Worktrees…") { startReview(board.safeToClear, now: now) }
                .buttonStyle(.borderedProminent)
                .disabled(store.isDeleting)
                .help("Review the \(board.safeToClear.count) merged or empty worktrees before clearing")
        }
    }

    /// While a cleanup runs, or after it, one line to follow or undo it.
    @ViewBuilder
    private func cleanupStatus() -> some View {
        if let progress = store.cleanupProgress {
            ModernGroupBox {
                cleanupRow(symbol: "hourglass", color: Color(nsColor: .systemBlue),
                           title: "Clearing \(progress.completed) of \(progress.total)",
                           detail: "Each one is checked again just before it goes.",
                           action: "Show Progress…", prominent: false) { presentation.showsCleanupProgress = true }
            }
        } else if let result = store.resultMessage {
            ModernGroupBox {
                cleanupRow(symbol: result.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                           color: Color(nsColor: result.isProblem ? .systemOrange : .systemGreen),
                           title: result.isProblem ? "Cleanup needs attention" : "Cleanup finished",
                           detail: result.freedBytes > 0 ? "Freed about \(BoardText.bytes(result.freedBytes))." : "See what changed, or undo it.",
                           action: "View Result…", prominent: false) { presentation.showsCleanupProgress = true }
            }
        }
    }

    private func cleanupRow(symbol: String, color: Color, title: String, detail: String, action: String,
                            prominent: Bool, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ModernIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if prominent {
                Button(action, action: perform).buttonStyle(.borderedProminent)
            } else {
                Button(action, action: perform)
            }
        }
        .padding(.horizontal, ModernMetrics.rowPadding)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                .padding(.leading, ModernMetrics.separatorInset)
        }
    }

    private func startStorageReview() {
        store.resultMessage = nil
        presentation.isReviewingCleanup = true
        showsStorageReview = true
    }

    private func storageReviewDismissed() {
        presentation.isReviewingCleanup = false
        if storageCleanupStarted { presentation.showsCleanupProgress = true }
        storageCleanupStarted = false
    }

    @ViewBuilder
    private func cacheRows(_ board: BranchesBoard, now: Date) -> some View {
        let folders = BranchesStorageSummary(board: board, toolStorage: store.toolStorage).cacheFolders
        if folders.isEmpty {
            ModernNoteRow(text: "No measured build cache in these folders.")
        }
        ForEach(folders) { item in
            card(item, BranchesBoard.lane(for: item) == .safeToClear ? .safe(fill: 0) : .look,
                 now: now, cacheBytes: item.size?.cacheBytes ?? 0)
        }
    }

    @ViewBuilder
    private func toolRows() -> some View {
        let entries = store.toolStorage.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        if store.isMeasuringToolStorage {
            ModernNoteRow(text: "Measuring…")
        } else if entries.isEmpty {
            ModernNoteRow(text: "Nothing to show. Folders under 10 MB are left out.")
        }
        ForEach(entries) { entry in
            PaperweightToolStorageRow(entry: entry, share: 0, isExpanded: expanded.contains("tool|" + entry.id),
                                      toggle: { toggle("tool|" + entry.id) })
        }
    }

    // MARK: Shared pieces

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 4)
    }

    /// The page's one figure, the bar under it and its key.
    private func figureCard(value: String, unit: String, caption: String? = nil,
                            configuration: PaperweightConfiguration) -> some View {
        let segments = ModernResourceCard.segments(configuration)
        let free = configuration.freeLayer
        return ModernCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit).font(.title3).foregroundStyle(.secondary)
                }
                if let caption {
                    Text(caption).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .padding(.top, -8)
                }
                CapacityBar(segments: segments, capacity: configuration.capacityBytes)
                CapacityLegend(segments: segments.filter { $0.bytes > 0 || $0.isMeasuring } + [
                    CapacitySegment(id: free.id, title: free.title, bytes: free.bytes,
                                    color: Color.primary.opacity(0.15), isMeasuring: free.isMeasuring,
                                    detail: configuration.amount(for: free))
                ])
            }
        }
    }

    private func amount(_ id: String, in configuration: PaperweightConfiguration) -> String? {
        configuration.layers.first { $0.id == id }.map { configuration.amount(for: $0) }
    }

    private func card(_ item: WorkItem, _ kind: WorkCard.Kind, now: Date, cacheBytes: Int64? = nil) -> some View {
        WorkCard(item: item, kind: kind, now: now, isExpanded: expanded.contains(item.id),
                 evidence: store.evidence[BranchesStore.evidenceKey(item)], isDeleting: store.isDeleting,
                 toggle: { toggle(item.id) }, loadEvidence: { store.loadEvidence(for: item) },
                 requestDelete: {
                     presentation.isReviewingCleanup = true
                     singleReview = DeleteReviewRequest(items: [item])
                 },
                 cacheBytes: cacheBytes)
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    /// Freeze reviewed rows while background checks finish, then check again
    /// before deleting, as in the individual review.
    private func startReview(_ items: [WorkItem], now: Date) {
        store.resultMessage = nil
        presentation.isReviewingCleanup = true
        clearReview = ClearReviewRequest(items: items, selection: ClearSelection(items: items, now: now), now: now)
    }

    private func reviewDismissed() {
        presentation.isReviewingCleanup = false
        if store.cleanupProgress != nil || store.resultMessage != nil { presentation.showsCleanupProgress = true }
    }
}

/// Behind a header that stays at the top of a scrolling page: the page's
/// own colour, so rows don't show through, and a hairline once it's stuck.
@available(macOS 14.0, *)
struct PinnedHeaderBackground: View {
    let space: String

    var body: some View {
        GeometryReader { proxy in
            let pinned = proxy.frame(in: .named(space)).minY <= 0.5
            ModernPalette.page
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 0.5)
                        .opacity(pinned ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.15), value: pinned)
        }
    }
}
