import AppKit
import Combine
import SwiftUI

/// The scene chooses a paperweight and layer; the lists keep the same reviews
/// and protections as the repository board.
@available(macOS 14.0, *)
struct BranchesRootView: View {
    @ObservedObject var store: BranchesStore
    var liveWork: LiveWorkMonitor?
    private let presentation: BranchesPaperweightPresentation?
    @State private var front: PaperweightID
    @State private var selectedLayerID: String
    @State private var summary: LiveWorkSummary
    @State private var preview = false
    @State private var moving = false
    @State private var commandID = 0
    @State private var sceneCommand: PaperweightSceneCommand?
    @State private var lastPresentationRequestID: UUID?
    @State private var query = ""
    @State private var projectID: String?
    @State private var clearReview: ClearReviewRequest?
    @State private var expanded: Set<String> = []
    @State private var singleReview: DeleteReviewRequest?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: BranchesStore, liveWork: LiveWorkMonitor? = nil,
         initialFront: PaperweightID = .storage, initialSelectedLayerID: String? = nil,
         presentation: BranchesPaperweightPresentation? = nil) {
        self.store = store
        self.liveWork = liveWork
        self.presentation = presentation
        _front = State(initialValue: initialFront)
        _selectedLayerID = State(initialValue: initialSelectedLayerID ?? (initialFront == .storage ? "wt" : ""))
        _summary = State(initialValue: liveWork?.summary ?? LiveWorkSummary())
    }

    private var summaryUpdates: AnyPublisher<LiveWorkSummary, Never> {
        liveWork?.$summary.eraseToAnyPublisher() ?? Just(LiveWorkSummary()).eraseToAnyPublisher()
    }

    private var presentationUpdates: AnyPublisher<BranchesPaperweightPresentation.Request?, Never> {
        presentation?.$request.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    var body: some View {
        let now = Date()
        let everything = BranchesBoard.make(snapshot: store.snapshot, now: now)
        let shown = BranchesBoard.make(snapshot: store.snapshot, query: query, projectID: projectID, now: now)
        let picks = ClearSelection(items: everything.safeToClear, now: now)
        let selectedItems = picks.chosenItems(from: everything.safeToClear)
        let freeing = preview ? picks.bytes(from: everything.safeToClear) : 0
        let freeingCache = preview ? selectedItems.compactMap(\.size?.cacheBytes).reduce(0, +) : 0
        let memory = liveWork == nil
            ? PaperweightConfiguration(id: .memory, capacityBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
                                       layers: [], freeBytes: nil)
            : PaperweightData.memory(summary: summary, running: everything.running,
                                     physicalMemory: ProcessInfo.processInfo.physicalMemory)
        let storage = PaperweightData.storage(disk: store.diskSpace, board: everything,
                                             toolStorage: store.toolStorage,
                                             isMeasuring: store.isMeasuringToolStorage || !store.hasMeasuredToolStorage,
                                             freeing: freeing, freeingCacheBytes: freeingCache)
        let configuration = front == .storage ? storage : memory
        let selected = configuration.layers.first { $0.id == selectedLayerID } ?? configuration.freeLayer
        // The rail's Storage card shows today's disk, not the cleared preview.
        let measured = preview
            ? PaperweightData.storage(disk: store.diskSpace, board: everything, toolStorage: store.toolStorage,
                                      isMeasuring: store.isMeasuringToolStorage || !store.hasMeasuredToolStorage)
            : storage
        let breakdown = StorageBreakdown(storage: measured, freeableBytes: picks.bytes(from: everything.safeToClear), measuredAt: now)
        VStack(spacing: 0) {
            toolbar(projects: everything.projects)
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        PaperweightSceneView(
                            configurations: [memory, storage], front: front,
                            selectedLayerID: selectedLayerID,
                            ships: [.memory: store.memoryShip, .storage: store.storageShip],
                            command: sceneCommand,
                            onSelect: { id, layer in front = id; selectedLayerID = layer },
                            onSwap: { id in
                                front = id
                                let next = id == .storage ? storage : memory
                                selectedLayerID = next.layers.first?.id ?? next.freeLayer.id
                            },
                            onMovingChanged: { moving = $0 }
                        )
                        .frame(height: min(330, max(260, geometry.size.height * 0.58)))
                        .accessibilityHint("Click a paperweight or layer. Drag to turn, scroll or pinch to zoom, and double-click the table to reset.")

                        headline(everything, picks: picks, memory: memory, storage: storage, now: now)
                        shipPicker
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(selected.title) · \(selected.isMeasuring ? "Measuring…" : BoardText.bytes(selected.bytes))")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            Text(moving ? "Moving" : "Still").font(.caption).foregroundStyle(.secondary)
                        }
                        selectedRows(selected, board: shown, configuration: configuration, now: now)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            if let message = store.resultMessage, message.deletedCount == 0 {
                Divider()
                ResultBanner(message: message, store: store)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onReceive(summaryUpdates) { updated in if updated != summary { summary = updated } }
        .onReceive(presentationUpdates) { request in
            guard let request, request.id != lastPresentationRequestID else { return }
            lastPresentationRequestID = request.id
            let next = request.front == .storage ? storage : memory
            selectedLayerID = request.selectedLayer(in: next, currentFront: front, currentLayer: selectedLayerID)
            front = request.front
        }
        .onAppear { ensureSelection(configuration) }
        .onChange(of: breakdown.map { [$0.worktreeBytes, $0.cacheBytes, $0.toolBytes, $0.freeableBytes] }) { _, _ in
            if let breakdown { store.recordStorageBreakdown(breakdown) }
        }
        .onChange(of: configuration.layers.map(\.id)) { _, _ in ensureSelection(configuration) }
        .onChange(of: projectID) { _, value in
            if let value, !everything.projects.contains(where: { $0.id == value }) { projectID = nil }
        }
        .sheet(item: $singleReview) { request in
            DeleteReviewView(request: request) { chosen in
                singleReview = nil
                preview = false
                store.startDelete(chosen)
            } cancel: { singleReview = nil }
        }
        .sheet(item: $clearReview) { request in
            ClearReviewSheet(request: request, disk: store.diskSpace) { chosen in
                clearReview = nil
                expanded = []
                preview = false
                store.startDelete(chosen)
            } cancel: { clearReview = nil }
        }
    }

    private func ensureSelection(_ configuration: PaperweightConfiguration) {
        guard selectedLayerID != configuration.freeLayer.id,
              !configuration.layers.contains(where: { $0.id == selectedLayerID }) else { return }
        selectedLayerID = configuration.layers.first?.id ?? configuration.freeLayer.id
    }

    private func send(_ kind: PaperweightSceneCommand.Kind) {
        commandID += 1
        sceneCommand = PaperweightSceneCommand(id: commandID, kind: kind)
    }

    private var shipPicker: some View {
        HStack {
            Picker("Ship in the front paperweight", selection: Binding(
                get: { store.ship(for: front) },
                set: { ship in
                    store.chooseShip(ship, for: front)
                    send(.shipDrop)
                }
            )) {
                ForEach(PaperweightShipKind.allCases) { ship in Text(ship.title).tag(ship) }
            }
            .frame(maxWidth: 400, alignment: .leading)
            Spacer(minLength: 8)
        }
    }

    private func headline(_ board: BranchesBoard, picks: ClearSelection, memory: PaperweightConfiguration,
                          storage: PaperweightConfiguration, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if front == .storage {
                StorageActions(store: store, board: board, pickedBytes: picks.bytes(from: board.safeToClear),
                               pickedCount: picks.chosenItems(from: board.safeToClear).count,
                               isReviewing: clearReview != nil, now: now,
                               review: { startReview(board.safeToClear, now: now) },
                               previewDisk: preview ? DiskSpace(totalBytes: storage.capacityBytes,
                                                               availableBytes: storage.freeBytes ?? 0) : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(liveWork == nil ? "Memory isn't available" : "AI tools use \(LiveWorkText.memory(summary.memoryBytes)) of memory")
                        .font(.system(size: 17, weight: .semibold))
                    Text(liveWork == nil ? "No memory reading is available." : LiveWorkText.memorySentence(summary.memoryBytes))
                        .font(.callout).foregroundStyle(.secondary)
                    if let dev = memory.layers.first(where: { $0.id == "dev" }) {
                        Text("Other repository work uses \(BoardText.bytes(dev.bytes)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .trailing, spacing: 6) {
                if front == .storage {
                    Button(preview ? "Show today" : "Preview clearing") {
                        preview.toggle()
                        send(.preview)
                    }
                    .disabled(picks.bytes(from: board.safeToClear) <= 0 || store.isDeleting)
                }
                Button("Shake") { send(.shake) }
            }
        }
    }

    @ViewBuilder
    private func selectedRows(_ layer: PaperweightLayer, board: BranchesBoard,
                              configuration: PaperweightConfiguration, now: Date) -> some View {
        if configuration.allocationIsEstimated {
            Text(front == .storage
                 ? "Measured folder sizes can overlap. Layer shares are scaled to disk use."
                 : "Memory footprints can exceed physical memory when macOS compresses or swaps memory. Layer heights are capped to fit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if front == .storage {
            switch layer.id {
            case "wt":
                Text("Folder sizes below include their build cache, shown separately in the paperweight.")
                    .font(.caption).foregroundStyle(.secondary)
                worktreeRows(board, now: now)
            case "cache": cacheRows(BranchesStorageSummary(board: board, toolStorage: store.toolStorage), now: now)
            case "tool": toolStorageRows()
            case "free": Text("Room left on the disk holding your home folder.").foregroundStyle(.secondary)
            default: Text("The system, apps and your own files. usAIge doesn't clear these.").foregroundStyle(.secondary)
            }
        } else if liveWork == nil {
            Text("No memory reading is available.").foregroundStyle(.secondary)
        } else if layer.id == "mfree" {
            Text("Memory not counted under AI tools or repository work. Other apps may be using it.")
                .foregroundStyle(.secondary)
        } else {
            var seen: Set<Int32> = []
            let items = board.running.compactMap { item -> WorkItem? in
                let own = item.processes.filter { layer.processIDs.contains($0.id) && seen.insert($0.id).inserted }
                guard !own.isEmpty else { return nil }
                var row = item
                row.processes = own
                return row
            }
            let largest = items.map(memoryBytes).max() ?? 0
            if items.isEmpty {
                Text("This memory belongs to the app and its helpers outside repository folders.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                let bytes = memoryBytes(item)
                card(item, .running, now: now, share: largest > 0 ? Double(bytes) / Double(largest) : 0,
                     color: layerColor(layer.colorHex))
            }
        }
    }

    private func layerColor(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }

    private func memoryBytes(_ item: WorkItem) -> UInt64 {
        var seen: Set<Int32> = []
        return item.processes.reduce(0) { $0 + (seen.insert($1.id).inserted ? $1.memoryBytes : 0) }
    }

    /// Freeze reviewed rows while background checks finish, then check again
    /// before deleting, as in the individual review.
    private func startReview(_ items: [WorkItem], now: Date, only group: ClearGroup? = nil) {
        var start = ClearSelection(items: items, now: now)
        if let group { start.chosen = Set(items.filter { ClearGroup.group(for: $0, now: now) == group }.map(\.id)) }
        preview = false
        store.resultMessage = nil
        clearReview = ClearReviewRequest(items: items, selection: start, now: now)
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Toolbar

    private func toolbar(projects: [ProjectChoice]) -> some View {
        HStack(spacing: 10) {
            searchField
            if projects.count > 1 { projectChips(projects) }
            Spacer(minLength: 8)
            activityView
            recentlyDeletedMenu
            Menu {
                Button("Read Everything Again") {
                    store.refresh()
                    store.loadToolStorage(force: true)
                }
                Button("Add Folder…") { chooseFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Read again, or add a repository no AI tool has worked in")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find a branch or what it did", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 230, height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }

    private func projectChips(_ projects: [ProjectChoice]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip("All", isOn: projectID == nil) { projectID = nil }
                ForEach(projects) { project in
                    chip(project.name, isOn: projectID == project.id) {
                        projectID = projectID == project.id ? nil : project.id
                    }
                }
            }
        }
        .frame(maxWidth: 300)
        .frame(minWidth: 0)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .background(
                    isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private var activityView: some View {
        switch store.snapshot.activity {
        case .idle, .clearing:
            EmptyView()
        case .readingSessions:
            progress("Reading sessions…")
        case let .checking(done, total):
            progress("Checking \(done) of \(total)…")
        case let .measuring(done, total):
            progress("Measuring \(done) of \(total)…")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .fixedSize()
    }

    /// Undo for anything deleted lately, once the result has gone or the
    /// window has been closed since.
    @ViewBuilder
    private var recentlyDeletedMenu: some View {
        let records = BranchesPresentation.restorable(store.snapshot.deletions, now: Date())
        if !records.isEmpty {
            Menu("Recently Deleted") {
                ForEach(records) { record in
                    Button("Restore \(record.displayName)") {
                        Task { await store.undo([record]) }
                    }
                }
            }
            .fixedSize()
            .disabled(store.isDeleting)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder inside a Git repository."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addFolder(url.path)
    }


    private func card(_ item: WorkItem, _ kind: WorkCard.Kind, now: Date, share: Double, color: Color,
                      cacheBytes: Int64? = nil) -> some View {
        WorkCard(item: item, kind: kind, now: now, isExpanded: expanded.contains(item.id),
                 evidence: store.evidence[BranchesStore.evidenceKey(item)], isDeleting: store.isDeleting,
                 toggle: { toggle(item.id) }, loadEvidence: { store.loadEvidence(for: item) },
                 requestDelete: { singleReview = DeleteReviewRequest(items: [item]) },
                 tubeShare: share, tubeColor: color, cacheBytes: cacheBytes)
    }

    private func groupHeading(_ title: String, count: Int, bytes: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            Text("\(count)").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(BoardText.bytes(bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func worktreeRows(_ board: BranchesBoard, now: Date) -> some View {
        let largest = max(board.needsLook.map(\.bytes).max() ?? 0, board.safeFolders.compactMap(\.size?.totalBytes).max() ?? 0)
        let color = layerColor(0xE2729A)
        if store.snapshot.gitIsMissing {
            LaneEmpty(text: "Git isn't installed. Install the Xcode Command Line Tools to see branches and worktrees here.")
        } else if store.snapshot.items.isEmpty, store.snapshot.notCheckedFolders.isEmpty, store.snapshot.activity == .idle {
            LaneEmpty(text: "No repositories yet. Use Add Folder in the … menu, or work in a repository with an AI tool.")
        }
        groupHeading("Needs a look", count: board.needsLookCount, bytes: board.needsLookBytes)
        if board.needsLook.isEmpty {
            LaneEmpty(text: "Work that exists only on this Mac, or isn't on main yet, shows here.")
        }
        ForEach(board.needsLook) { entry in
            let fill = largest > 0 ? Double(entry.bytes) / Double(largest) : 0
            switch entry {
            case let .item(item):
                card(item, .look, now: now, share: fill, color: color)
            case let .copy(copy):
                LeftoverCopyCard(copy: copy, now: now, isExpanded: expanded.contains(entry.id),
                                 toggle: { toggle(entry.id) }, tubeShare: fill) {
                    ForEach(copy.items) { item in
                        card(item, .look, now: now, share: largest > 0 ? Double(item.size?.totalBytes ?? 0) / Double(largest) : 0,
                             color: color)
                    }
                }
            case let .notChecked(folder):
                NotCheckedCard(folder: folder, isExpanded: expanded.contains(entry.id), toggle: { toggle(entry.id) }) {
                    store.addFolder(folder)
                }
            case let .unreadable(repository):
                UnreadableCard(repository: repository, isExpanded: expanded.contains(entry.id), toggle: { toggle(entry.id) })
            }
        }
        if board.stillChecking > 0 {
            Text("Still checking \(board.stillChecking) more…").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            groupHeading("Safe to clear", count: board.safeToClear.count, bytes: board.safeBytes)
            if !board.safeToClear.isEmpty {
                Button("Clear…") { startReview(board.safeToClear, now: now) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isDeleting)
                    .help("Review exactly the \(board.safeToClear.count) shown here")
            }
        }
        if board.safeToClear.isEmpty {
            LaneEmpty(text: "Merged or empty branches and worktrees that nothing runs in show here.")
        }
        ForEach(board.safeFolders) { item in
            let fill = largest > 0 ? Double(item.size?.totalBytes ?? 0) / Double(largest) : 0
            card(item, .safe(fill: fill), now: now, share: fill, color: color)
        }
        ForEach([ClearGroup.branches, .records]) { group in
            let items = board.safe(in: group, now: now)
            if !items.isEmpty {
                SafeGroupCard(group: group, items: items, isExpanded: expanded.contains("group|" + group.rawValue),
                              isDeleting: store.isDeleting, toggle: { toggle("group|" + group.rawValue) },
                              review: { startReview(items, now: now, only: group) }) {
                    ForEach(items) { item in
                        card(item, .safe(fill: 0), now: now, share: 0, color: color)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cacheRows(_ totals: BranchesStorageSummary, now: Date) -> some View {
        groupHeading("Build cache", count: totals.cacheFolders.count, bytes: totals.bytes(for: .buildCache))
        Text("Cache inside worktree folders. Delete… reviews the whole folder, including its cache.")
            .font(.caption).foregroundStyle(.secondary)
        if totals.cacheFolders.isEmpty { LaneEmpty(text: "No measured build cache in these folders.") }
        let largest = totals.cacheFolders.first?.size?.cacheBytes ?? 0
        ForEach(totals.cacheFolders) { item in
            let bytes = item.size?.cacheBytes ?? 0
            card(item, BranchesBoard.lane(for: item) == .safeToClear ? .safe(fill: 0) : .look,
                 now: now, share: largest > 0 ? Double(bytes) / Double(largest) : 0,
                 color: layerColor(0x3DB58C), cacheBytes: bytes)
        }
    }

    @ViewBuilder
    private func toolStorageRows() -> some View {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let entries = store.toolStorage.filter { entry in
            let text = [entry.name, entry.path ?? "", entry.kind.label].joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        groupHeading("Tool storage", count: entries.count, bytes: entries.reduce(0) { $0 + $1.bytes })
        Text("Outside repositories. Shown only: usAIge clears nothing here.")
            .font(.caption).foregroundStyle(.secondary)
        if store.isMeasuringToolStorage {
            HStack { ProgressView().controlSize(.small); Text("Measuring…").font(.caption) }
        } else if entries.isEmpty {
            LaneEmpty(text: "Nothing to show. Folders under 10 MB are left out.")
        }
        let largest = entries.first?.bytes ?? 0
        ForEach(entries) { entry in
            PaperweightToolStorageRow(entry: entry, share: largest > 0 ? Double(entry.bytes) / Double(largest) : 0, isExpanded: expanded.contains("tool|" + entry.id),
                               toggle: { toggle("tool|" + entry.id) })
        }
    }
}

/// Keep the storage headline and actions together as clearing progresses.
@available(macOS 14.0, *)
private struct StorageActions: View {
    @ObservedObject var store: BranchesStore
    let board: BranchesBoard
    let pickedBytes: Int64
    let pickedCount: Int
    let isReviewing: Bool
    let now: Date
    let review: () -> Void
    var previewDisk: DiskSpace? = nil

    private var disk: DiskSpace? { store.diskSpace }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(3)
                .monospacedDigit()
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail)
            if let problems {
                Text(problems)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .help(problems)
            }
            actions.padding(.top, 4)
        }
    }

    private var clearedMessage: BranchesStore.ResultMessage? {
        guard !isReviewing, let message = store.resultMessage, message.deletedCount > 0 else { return nil }
        return message
    }

    private var clearing: (done: Int, total: Int)? {
        if case let .clearing(done, total) = store.snapshot.activity { return (done, total) }
        return nil
    }

    private var defaultCount: Int {
        ClearSelection(items: board.safeToClear, now: now).chosen.count
    }

    private var headline: String {
        if let clearing { return "Clearing \(clearing.done + 1) of \(clearing.total)…" }
        if let message = clearedMessage {
            return message.freedBytes > 0
                ? "Freed about \(BoardText.bytes(message.freedBytes))"
                : "Cleared \(message.deletedCount) \(message.deletedCount == 1 ? "item" : "items")"
        }
        if store.snapshot.gitIsMissing { return "Git isn't installed" }
        if let previewDisk { return "About \(BoardText.bytes(previewDisk.availableBytes)) free after clearing" }
        if pickedBytes > 0 { return "You can free about \(BoardText.bytes(pickedBytes))" }
        if isReviewing {
            return pickedCount == 0 ? "Nothing ticked yet" : "You can tidy \(pickedCount) \(pickedCount == 1 ? "item" : "items")"
        }
        if !board.safeToClear.isEmpty {
            let count = pickedCount > 0 ? pickedCount : board.safeToClear.count
            return "You can tidy \(count) \(count == 1 ? "item" : "items")"
        }
        if store.snapshot.activity != .idle { return "Reading your repositories…" }
        return "Nothing to clear right now"
    }

    private var freeText: String? {
        disk.map { "\(BoardText.bytes($0.availableBytes)) free now" }
    }

    private var detail: String {
        if clearing != nil {
            return "Each one is checked again just before it goes, and left alone if anything changed."
        }
        if let message = clearedMessage {
            var parts = ["\(message.deletedCount) \(message.deletedCount == 1 ? "item" : "items") cleared."]
            if let freeText { parts.append(freeText + ".") }
            if !message.undoable.isEmpty { parts.append("Undo brings back branches and folders, not caches or ignored files.") }
            return parts.joined(separator: " ")
        }
        if let previewDisk {
            return "\(LiveWorkText.percent(previewDisk.usedShare())) used after, down from \(LiveWorkText.percent(disk?.usedShare() ?? 0)). Preview of the default clear choice."
        }
        var parts: [String] = []
        if let disk, pickedBytes > 0 {
            parts.append("\(BoardText.bytes(disk.availableBytes)) free now, about \(BoardText.bytes(disk.availableBytes + pickedBytes)) after.")
        } else if let freeText {
            parts.append(freeText + ".")
        }
        if board.safeToClear.isEmpty {
            parts.append(store.snapshot.activity == .idle
                ? "Everything here is running or holds work worth a look."
                : "Branches that are merged or empty show up here as they're checked.")
            return parts.joined(separator: " ")
        }
        let chosen = ClearSelection(items: board.safeToClear, now: now).chosenItems(from: board.safeToClear)
        let cache = chosen.compactMap(\.size?.cacheBytes).reduce(0, +)
        parts.append("\(defaultCount) merged or empty"
            + (cache > 0 ? ", \(BoardText.bytes(cache)) of it cache a build makes again." : "."))
        if case .measuring = store.snapshot.activity { parts.append("Still measuring.") }
        return parts.joined(separator: " ")
    }

    private var problems: String? {
        guard let message = clearedMessage, message.isProblem else { return nil }
        let lines = message.text.split(separator: "\n").dropFirst()
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { actionButtons }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if clearing != nil {
            Button("Stop") { store.stopDeleting() }
        } else if let message = clearedMessage {
            if !message.undoable.isEmpty {
                Button("Undo") { Task { await store.undo(message.undoable) } }
                    .disabled(store.isDeleting)
            }
            if defaultCount > 0 {
                Button("Review the Rest…", action: review)
            }
            Button("Done") { store.resultMessage = nil }
        } else if !isReviewing, !board.safeToClear.isEmpty {
            Button("Review and Clear…", action: review)
                .buttonStyle(.borderedProminent)
                .disabled(store.isDeleting)
                .help("Review all \(board.safeToClear.count) safe items")
        }
    }
}

/// The disk drawn as water: the darker part stays, the lighter band above it
/// is what the chosen items would free.
@available(macOS 14.0, *)
private struct DiskTank: View {
    let disk: DiskSpace?
    let freeing: Int64
    /// The smaller tank in the review.
    var compact = false

    private var now: Double { disk?.usedShare() ?? 0 }
    private var after: Double { disk?.usedShare(freeing: freeing) ?? 0 }

    var body: some View {
        BoardTank(
            level: after,
            secondaryLevel: now,
            color: LiveWorkText.severity(now).color,
            // The smaller tank shows the disk after the ticked items go.
            percent: disk == nil ? "–" : LiveWorkText.percent(compact ? after : now),
            label: compact ? "after" : "disk used",
            compact: compact
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let disk else { return "Not read" }
        var text = "\(LiveWorkText.percent(now)) used, \(BoardText.bytes(disk.availableBytes)) free"
        if freeing > 0 { text += ", \(LiveWorkText.percent(after)) after clearing" }
        return text
    }
}

/// The review keeps its small tank separate from the interactive scene.
@available(macOS 14.0, *)
private struct BoardTank: View {
    let level: Double
    let secondaryLevel: Double
    let color: Color
    let percent: String
    let label: String
    var compact = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 20 : 26, style: .continuous) }

    var body: some View {
        // Moving water is for the window being looked at, not left behind.
        let moves = activeState == .key && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !moves)) { context in
            let phase = moves ? context.date.timeIntervalSinceReferenceDate * 1.4 : 0.6
            ZStack {
                WaterShape(level: secondaryLevel, phase: phase + 1.7, amplitude: 2.5, wavelength: 70)
                    .fill(color.opacity(0.24))
                WaterShape(level: level, phase: phase, amplitude: 2.5, wavelength: 70)
                    .fill(color.opacity(0.5))
            }
            .animation(moves ? .easeInOut(duration: 1.1) : nil, value: level)
            .animation(moves ? .easeInOut(duration: 1.1) : nil, value: secondaryLevel)
        }
        .clipShape(shape)
        .overlay {
            VStack(spacing: 0) {
                Text(percent)
                    .font(.system(size: compact ? 20 : 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(moves ? .snappy : nil, value: level)
                Text(label)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.7))
            }
        }
        .frame(width: compact ? 78 : 104, height: compact ? 98 : 132)
        .background { BoardGlass(shape: shape) }
        .overlay { shape.stroke(Color.primary.opacity(0.16), lineWidth: 1) }
    }
}

/// The rail's glass where macOS has it, and its material where it doesn't.
@available(macOS 14.0, *)
struct BoardGlass<S: Shape>: View {
    let shape: S

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

@available(macOS 14.0, *)
private struct LaneEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
    }
}

// MARK: Review and clear

/// What a review opens with: the rows as they were, and which start ticked.
struct ClearReviewRequest: Identifiable {
    let id = UUID()
    let items: [WorkItem]
    let selection: ClearSelection
    let now: Date
}

/// Picks what to clear, a group at a time, with every row inside a group
/// one click away. Its own tank shows the disk after the ticked rows go.
@available(macOS 14.0, *)
private struct ClearReviewSheet: View {
    let request: ClearReviewRequest
    let disk: DiskSpace?
    let confirm: ([WorkItem]) -> Void
    let cancel: () -> Void
    @State private var selection: ClearSelection
    @State private var opened: Set<ClearGroup> = []

    init(
        request: ClearReviewRequest,
        disk: DiskSpace?,
        confirm: @escaping ([WorkItem]) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        self.disk = disk
        self.confirm = confirm
        self.cancel = cancel
        _selection = State(initialValue: request.selection)
    }

    private var items: [WorkItem] { request.items }
    private var now: Date { request.now }

    var body: some View {
        let chosen = selection.chosenItems(from: items)
        let bytes = selection.bytes(from: items)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                DiskTank(disk: disk, freeing: bytes, compact: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bytes > 0 ? "Free about \(BoardText.bytes(bytes))"
                         : chosen.isEmpty ? "Nothing ticked yet"
                         : "Tidy \(chosen.count) \(chosen.count == 1 ? "item" : "items")")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: bytes)
                    if let disk {
                        Text("\(BoardText.bytes(disk.availableBytes)) free now, about \(BoardText.bytes(disk.availableBytes + bytes)) after.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Each one is checked again just before it goes, and left alone if anything changed. Nothing on GitHub or any other remote is touched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ClearGroup.allCases) { group in
                        let members = items.filter { ClearGroup.group(for: $0, now: now) == group }
                        if !members.isEmpty { groupRow(group, members) }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack(alignment: .center, spacing: 10) {
                Text("Undo brings back branches and folders, not caches or ignored files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Clear 1 Item" : "Clear \(chosen.count) Items", role: .destructive) {
                    confirm(chosen)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(chosen.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 780)
        .frame(minHeight: 440, idealHeight: 680, maxHeight: 860)
    }

    private func groupRow(_ group: ClearGroup, _ members: [WorkItem]) -> some View {
        let bytes = members.compactMap(\.size?.totalBytes).reduce(0, +)
        let isOpen = opened.contains(group)
        let toggleOpen = {
            withAnimation(.snappy(duration: 0.2)) {
                if isOpen { opened.remove(group) } else { opened.insert(group) }
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Checkbox(state: selection.state(of: members)) {
                    selection.set(members, to: selection.state(of: members) != true)
                }
                .accessibilityLabel(group.title)
                Button(action: toggleOpen) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(members.count) \(group.title.prefix(1).lowercased() + group.title.dropFirst())")
                                .font(.body.weight(.semibold))
                            Text(group.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(bytes > 0 ? BoardText.bytes(bytes) : "No space")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        FoldChevron(isExpanded: isOpen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Hide the \(members.count)" : "Show the \(members.count)")
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(members.sorted { ($0.size?.totalBytes ?? 0, $1.id) > ($1.size?.totalBytes ?? 0, $0.id) }) { item in
                        itemRow(item)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private func itemRow(_ item: WorkItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Checkbox(state: selection.chosen.contains(item.id)) {
                selection.set([item], to: !selection.chosen.contains(item.id))
            }
            .accessibilityLabel(item.workTitle)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.workTitle).lineLimit(1)
                Text(removalText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ShowInFinderButton(item: item)
        }
    }

    private func removalText(_ item: WorkItem) -> String {
        var parts = [item.branch ?? "No branch"]
        parts.append("removes " + ListFormatter.localizedString(byJoining: item.whatDeleteRemoves))
        if let bytes = item.size?.totalBytes, bytes > 0 { parts.append(BoardText.bytes(bytes)) }
        if let used = item.lastUsedAt { parts.append("used " + BoardText.age(used, now: now)) }
        return parts.joined(separator: " · ")
    }
}

/// Reveals a row's folder, or its repository's when the row has no folder.
@available(macOS 14.0, *)
private struct ShowInFinderButton: View {
    let item: WorkItem

    private var target: (path: String, help: String)? {
        if let path = item.worktreePath, item.facts.folderExists, item.facts.folderReadable {
            return (path, "Show this folder in Finder")
        }
        let repository = item.repositoryID.hasSuffix("/.git") ? String(item.repositoryID.dropLast(5)) : item.repositoryID
        guard FileManager.default.fileExists(atPath: repository) else { return nil }
        return (repository, "This branch has no folder of its own. Shows its repository in Finder.")
    }

    var body: some View {
        if let target {
            Button {
                FolderActions.showInFinder(target.path)
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(target.help)
            .fixedSize()
        }
    }
}

/// The fold and unfold mark in a card's corner.
@available(macOS 14.0, *)
struct FoldChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.06), in: Circle())
            .animation(.snappy(duration: 0.2), value: isExpanded)
            .accessibilityHidden(true)
    }
}

/// A checkbox that can show "some", for a group with only part ticked.
@available(macOS 14.0, *)
private struct Checkbox: View {
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(state == false ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityValue(state == true ? "On" : state == nil ? "Some" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Folder actions

@MainActor
enum FolderActions {
    static func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// A new Terminal window in the folder.
    static func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)],
            withApplicationAt: terminal,
            configuration: configuration
        )
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Delete review

struct DeleteReviewRequest: Identifiable {
    let id = UUID()
    let items: [WorkItem]
}

/// Lists exactly what goes and what stays. A row with a reason to think twice
/// starts unticked, so deleting it takes a deliberate click.
@available(macOS 14.0, *)
struct DeleteReviewView: View {
    let request: DeleteReviewRequest
    let confirm: ([WorkItem]) -> Void
    let cancel: () -> Void
    @State private var chosen: Set<WorkItem.ID>

    init(request: DeleteReviewRequest, confirm: @escaping ([WorkItem]) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.confirm = confirm
        self.cancel = cancel
        let now = Date()
        _chosen = State(initialValue: Set(
            request.items.filter { BranchesPresentation.cautions(for: $0, now: now).isEmpty }.map(\.id)
        ))
    }

    private var chosenItems: [WorkItem] { request.items.filter { chosen.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.items.count == 1 ? "Delete this?" : "Delete these \(request.items.count) items?")
                    .font(.title3.weight(.semibold))
                Text("usAIge checks each one again just before deleting it, and stops if anything changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.items) { item in
                        row(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            VStack(alignment: .leading, spacing: 3) {
                Text("Stays: anything on GitHub or another remote, and every commit on main.")
                Text("Undo brings back the branch and folder, but not caches or ignored files.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(chosenItems.count <= 1 ? "Delete" : "Delete \(chosenItems.count) Items", role: .destructive) {
                    confirm(chosenItems)
                }
                .disabled(chosenItems.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func row(_ item: WorkItem) -> some View {
        let cautions = BranchesPresentation.cautions(for: item, now: Date())
        return Toggle(isOn: Binding(
            get: { chosen.contains(item.id) },
            set: { isOn in
                if isOn { chosen.insert(item.id) } else { chosen.remove(item.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.workTitle)
                    .lineLimit(2)
                Text(item.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(removalText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(cautions, id: \.self) { caution in
                    Text(caution)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func removalText(_ item: WorkItem) -> String {
        var text = "Removes " + ListFormatter.localizedString(byJoining: item.whatDeleteRemoves)
        if let bytes = item.size?.totalBytes, bytes > 0 {
            text += ", freeing about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        return text + "."
    }
}

// MARK: Result

@available(macOS 14.0, *)
private struct ResultBanner: View {
    let message: BranchesStore.ResultMessage
    @ObservedObject var store: BranchesStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: message.isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(message.isProblem ? Color.orange : Color.green)
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !message.undoable.isEmpty {
                Button("Undo") { Task { await store.undo(message.undoable) } }
                    .disabled(store.isDeleting)
            }
            Button {
                store.resultMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
