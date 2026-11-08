import AppKit
import Combine
import SwiftUI

enum BranchesPageMode { case worktrees, resources }

/// View filtering is separate from the classification of an individual item.
enum WorkStatusFilter: Hashable { case all, running, needsLook, safeToClear }

@available(macOS 14.0, *)
@MainActor
final class BranchesPageState: ObservableObject {
    @Published var front: PaperweightID
    @Published var selectedLayerID: String
    @Published var query = ""
    @Published var projectID: String?
    @Published var expanded: Set<String> = []
    @Published var cruisePaused = false
    @Published var workStatus: WorkStatusFilter = .all
    var lastPresentationRequestID: UUID?
    var lastOverviewFocusID: UUID?

    init(front: PaperweightID = .storage, selectedLayerID: String? = nil) {
        self.front = front
        self.selectedLayerID = selectedLayerID ?? (front == .storage ? "wt" : "")
    }
}

/// The resource ocean chooses a layer; the lists keep the same reviews
/// and protections as the repository board.
@available(macOS 14.0, *)
struct BranchesRootView: View {
    @ObservedObject var store: BranchesStore
    var mode: BranchesPageMode
    var liveWork: LiveWorkMonitor?
    private let overviewHeader: AnyView?
    private let presentation: BranchesPaperweightPresentation?
    @ObservedObject private var page: BranchesPageState
    @State private var summary: LiveWorkSummary
    @State private var preview = false
    @State private var commandID = 0
    @State private var sceneCommand: PaperweightSceneCommand?
    @AppStorage(CruiseWeather.defaultsKey) private var weatherName = CruiseWeather.automatic.rawValue
    @State private var memoryPressure: SystemMemoryPressure
    @State private var clearReview: ClearReviewRequest?
    @State private var singleReview: DeleteReviewRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: BranchesStore, liveWork: LiveWorkMonitor? = nil, agentStore: CodexAgentStore? = nil,
         initialFront: PaperweightID = .storage, initialSelectedLayerID: String? = nil,
         presentation: BranchesPaperweightPresentation? = nil, mode: BranchesPageMode = .resources,
         overviewHeader: AnyView? = nil) {
        self.store = store
        self.mode = mode
        self.liveWork = liveWork
        self.overviewHeader = overviewHeader
        self.presentation = presentation
        let state = presentation.map { mode == .worktrees ? $0.worktreePage : $0.resourcePage }
            ?? BranchesPageState(front: initialFront, selectedLayerID: initialSelectedLayerID)
        _page = ObservedObject(wrappedValue: state)
        _summary = State(initialValue: liveWork?.summary ?? LiveWorkSummary())
        _memoryPressure = State(initialValue: liveWork?.memoryPressure ?? .unknown)
    }

    private var front: PaperweightID { get { page.front } nonmutating set { page.front = newValue } }
    private var selectedLayerID: String { get { page.selectedLayerID } nonmutating set { page.selectedLayerID = newValue } }
    private var query: String { get { page.query } nonmutating set { page.query = newValue } }
    private var projectID: String? { get { page.projectID } nonmutating set { page.projectID = newValue } }
    private var expanded: Set<String> { get { page.expanded } nonmutating set { page.expanded = newValue } }
    private var cruisePaused: Bool { get { page.cruisePaused } nonmutating set { page.cruisePaused = newValue } }
    private var lastPresentationRequestID: UUID? {
        get { page.lastPresentationRequestID }
        nonmutating set { page.lastPresentationRequestID = newValue }
    }

    private var weather: CruiseWeather {
        CruiseWeather(rawValue: weatherName) ?? .automatic
    }

    private var summaryUpdates: AnyPublisher<LiveWorkSummary, Never> {
        liveWork?.$summary.eraseToAnyPublisher() ?? Just(LiveWorkSummary()).eraseToAnyPublisher()
    }

    private var memoryPressureUpdates: AnyPublisher<SystemMemoryPressure, Never> {
        liveWork?.$memoryPressure.eraseToAnyPublisher() ?? Just(.unknown).eraseToAnyPublisher()
    }

    private var diskUpdates: AnyPublisher<DiskSpace?, Never> {
        // The store reads immediately on opening. Subsequent monitor samples
        // keep both the ocean and its weather current without another timer.
        liveWork?.$diskSpace.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    private var weatherStatus: ResourceWeatherStatus {
        ResourceWeatherStatus.make(for: front, memoryPressure: memoryPressure, disk: store.diskSpace)
    }

    private var presentationUpdates: AnyPublisher<BranchesPaperweightPresentation.Request?, Never> {
        presentation?.$request.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    private var focusUpdates: AnyPublisher<BranchesPaperweightPresentation.FocusRequest?, Never> {
        presentation?.$focusRequest.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
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
            if mode == .worktrees {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Branches and Worktrees").font(.largeTitle.weight(.semibold))
                            Text("See what’s running, review unfinished work, and clear merged branches.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                        if store.snapshot.activity != .idle { activityView }
                        worktreeRows(shown, now: now)
                    }
                    .padding(24)
                }
            } else {
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let overviewHeader { overviewHeader.id(OverviewSection.overview) }
                        overview(memory: memory, storage: storage, board: everything, now: now)
                            .padding(.horizontal, 4)
                            .padding(.top, 20)
                            .padding(.bottom, 4)
                            .id(OverviewSection.resources)
                        ResourceOceanView(
                            configuration: configuration, selectedLayerID: selectedLayerID,
                            weather: weatherStatus.resolvedWeather(preference: weather),
                            ship: store.ship(for: front), isActive: !cruisePaused,
                            command: sceneCommand,
                            onSelect: { selectedLayerID = $0 }
                        )
                        .frame(height: min(560, max(420, geometry.size.height * 0.7)))
                        .padding(.horizontal, -20)

                        HStack(alignment: .top, spacing: 12) {
                            shipPicker.frame(width: 220)
                            weatherControls
                            Spacer(minLength: 8)
                            Button("Shake", systemImage: "water.waves") { send(.shake) }
                                .disabled(cruisePaused || reduceMotion)
                                .help("Make waves; the unsinkable ship rides them and rights itself")
                            Button(cruisePaused ? "Resume" : "Pause", systemImage: cruisePaused ? "play.fill" : "pause.fill") {
                                cruisePaused.toggle()
                            }
                            .disabled(reduceMotion)
                            .help(reduceMotion ? "Animation is paused by Reduce Motion" : "Pause or resume the ocean")
                        }
                        .padding(.horizontal, 4)

                        oceanLayers(configuration)

                        if front == .storage, overviewHeader != nil {
                            HStack {
                                StorageRecoveryView(store: store, showProgress: showCleanupProgress)
                                Spacer(minLength: 12)
                                previewClearingButton(picks: picks, board: everything)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                        } else {
                            headline(everything, picks: picks, memory: memory, storage: storage, now: now)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider()

                        if overviewHeader == nil || front != .storage || selected.id != "wt" {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(selected.title) · \(selected.isMeasuring ? "Measuring…" : BoardText.bytes(selected.bytes))")
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 8)
                                Picker("Layer", selection: $page.selectedLayerID) {
                                    ForEach(configuration.layers + [configuration.freeLayer]) { layer in
                                        Text(layer.title).tag(layer.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 200)
                            }
                            selectedRows(selected, board: shown, configuration: configuration, now: now)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                        }

                        if overviewHeader != nil {
                            VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Branches and Worktrees")
                                    .font(.title2.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 12)
                                Button(store.snapshot.activity == .idle ? "Rescan" : "Scanning…",
                                       systemImage: "arrow.clockwise") {
                                    store.refresh()
                                    store.loadToolStorage(force: true)
                                    store.readDiskSpace()
                                }
                                .controlSize(.large)
                                .disabled(store.snapshot.activity != .idle || store.isDeleting)
                                .help("Scan branches, worktrees, and local tool storage again")
                            }
                            Text("Running work, unfinished changes, and merged or empty folders. Folder sizes include their build cache.")
                                .font(.callout).foregroundStyle(.secondary)
                            if store.snapshot.activity != .idle { activityView }
                            worktreeRows(shown, now: now)
                            }
                            .padding(.top, 24)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                            .id(OverviewSection.branches)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .onReceive(focusUpdates) { request in
                    guard overviewHeader != nil, let request, request.id != page.lastOverviewFocusID else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard presentation?.focusRequest?.id == request.id,
                              request.id != page.lastOverviewFocusID else { return }
                        scroll.scrollTo(request.section, anchor: .top)
                        page.lastOverviewFocusID = request.id
                    }
                }
                }
            }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 620, minHeight: 480)
        .searchable(text: $page.query, placement: .toolbar, prompt: "Find a branch or worktree")
        .toolbar {
            ToolbarItemGroup {
                if everything.projects.count > 1 {
                    Picker("Project", selection: $page.projectID) {
                        Text("All Projects").tag(String?.none)
                        ForEach(everything.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .frame(maxWidth: 180)
                }
            }
        }
        .onReceive(summaryUpdates) { updated in if updated != summary { summary = updated } }
        .onReceive(memoryPressureUpdates) { memoryPressure = $0 }
        .onReceive(diskUpdates) { store.updateObservedDiskSpace($0) }
        .onReceive(presentationUpdates) { request in
            guard let request, request.id != lastPresentationRequestID else { return }
            lastPresentationRequestID = request.id
            let next = request.front == .storage ? storage : memory
            selectedLayerID = request.selectedLayer(in: next, currentFront: front, currentLayer: selectedLayerID)
            front = request.front
        }
        .onAppear {
            ensureSelection(configuration)
        }
        .onChange(of: breakdown.map { [$0.worktreeBytes, $0.cacheBytes, $0.toolBytes, $0.freeableBytes] }) { _, _ in
            if let breakdown { store.recordStorageBreakdown(breakdown) }
        }
        .onChange(of: configuration.layers.map(\.id)) { _, _ in ensureSelection(configuration) }
        .onChange(of: projectID) { _, value in
            if let value, !everything.projects.contains(where: { $0.id == value }) { projectID = nil }
        }
        .sheet(item: $singleReview, onDismiss: reviewDismissed) { request in
            DeleteReviewView(request: request) { chosen in
                singleReview = nil
                preview = false
                store.startDelete(chosen)
            } cancel: { singleReview = nil }
        }
        .sheet(item: $clearReview, onDismiss: reviewDismissed) { request in
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

    private func showCleanupProgress() {
        presentation?.showsCleanupProgress = true
    }

    private func reviewDismissed() {
        presentation?.isReviewingCleanup = false
        if store.cleanupProgress != nil || store.resultMessage != nil { showCleanupProgress() }
    }

    private func previewClearingButton(picks: ClearSelection, board: BranchesBoard) -> some View {
        Button(preview ? "Show today" : "Preview clearing") {
            preview.toggle()
            send(.preview)
        }
        .disabled(picks.bytes(from: board.safeToClear) <= 0 || store.isDeleting)
    }

    private func send(_ kind: PaperweightSceneCommand.Kind) {
        commandID += 1
        sceneCommand = PaperweightSceneCommand(id: commandID, kind: kind)
    }

    private func overview(memory: PaperweightConfiguration, storage: PaperweightConfiguration,
                          board: BranchesBoard, now: Date) -> some View {
        let amount = Text(front == .storage
                          ? storage.freeBytes.map { "\(BoardText.bytes($0)) free" } ?? "Measuring…"
                          : liveWork == nil ? "Unavailable"
                          : memory.freeBytes != nil ? "\(BoardText.bytes(memory.usedBytes)) in use" : "Measuring…")
            .font(.system(size: 32, weight: .light, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                if overviewHeader != nil {
                    Text("Local workspace usage")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Text(front == .storage ? "Storage" : "Memory")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                if front == .storage {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            amount
                            StorageCleanupSummary(store: store)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 6) {
                            amount
                            StorageCleanupSummary(store: store)
                        }
                    }
                } else {
                    amount
                }
                Text(preview && front == .storage
                     ? "Preview after clearing the default selection."
                     : front == .memory ? "AI tools and repository work form the ocean’s layers."
                     : "Click an ocean layer to explore what’s using this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    paperweightButton(memory)
                    paperweightButton(storage)
                }
                if front == .storage {
                    StorageCleanupButton(store: store,
                                         review: { startReview(board.safeToClear, now: now) },
                                         showProgress: showCleanupProgress)
                }
            }
        }
    }

    private func oceanLayers(_ configuration: PaperweightConfiguration) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(configuration.layers + [configuration.freeLayer]) { layer in
                    Button {
                        selectedLayerID = layer.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(layerColor(ResourceOceanRenderData.pigmentHex(for: layer))).frame(width: 8, height: 8)
                            Text(layer.title)
                            Text(layer.isMeasuring ? "Measuring…" : BoardText.bytes(layer.bytes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedLayerID == layer.id ? .accentColor : .secondary)
                    .accessibilityAddTraits(selectedLayerID == layer.id ? .isSelected : [])
                    .accessibilityHint("Show this ocean layer’s details")
                }
            }
        }
    }

    private func paperweightButton(_ configuration: PaperweightConfiguration) -> some View {
        let selected = front == configuration.id
        return Button {
            guard !selected else { return }
            front = configuration.id
            selectedLayerID = configuration.id == .storage ? "wt" : configuration.layers.first?.id ?? configuration.freeLayer.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(configuration.id == .memory ? "Memory" : "Storage",
                      systemImage: configuration.id == .memory ? "memorychip" : "internaldrive")
                    .font(.callout.weight(.medium))
                Text(configuration.freeBytes != nil && configuration.capacityBytes > 0
                     ? "\(LiveWorkText.percent(Double(configuration.usedBytes) / Double(configuration.capacityBytes))) used"
                     : "Measuring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Enter this resource’s ocean and explore its layers")
    }

    private var shipPicker: some View {
        PaperweightShipPicker(selected: store.ship(for: front)) { ship in
            store.chooseShip(ship, for: front)
            send(.shipDrop)
        }
    }

    private var weatherControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Weather").foregroundStyle(.secondary)
                Picker("Weather", selection: $weatherName) {
                    ForEach(CruiseWeather.allCases) { condition in
                        Label(condition.title, systemImage: condition.symbol).tag(condition.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .help("Automatic weather follows this resource’s condition. Choose a weather condition to keep it.")
            }
            Text(weather == .automatic ? weatherStatus.summary : "Manual weather · \(weather.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 230, alignment: .leading)
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
                Text("Folder sizes below include their build cache, shown separately in the ocean.")
                    .font(.caption).foregroundStyle(.secondary)
                worktreeRows(board, now: now)
            case "cache": cacheRows(BranchesStorageSummary(board: board, toolStorage: store.toolStorage), now: now)
            case "tool": toolStorageRows()
            case "free": Text("Room left on the disk holding your home folder.").foregroundStyle(.secondary)
            default: Text("The system, apps and your own files. usAIge doesn't clear these.").foregroundStyle(.secondary)
            }
        } else if liveWork == nil {
            Text("No memory reading is available.").foregroundStyle(.secondary)
        } else {
            let rows = PaperweightData.memoryRows(for: layer, in: configuration, running: board.running)
            if layer.id == configuration.freeLayer.id {
                Text("Memory not counted under AI tools or repository work. Other apps may be using it.")
                    .foregroundStyle(.secondary)
            } else if rows.measured.isEmpty, rows.sessionOnly.isEmpty {
                Text("This memory belongs to the app and its helpers outside repository folders.")
                    .foregroundStyle(.secondary)
            }
            let largest = rows.measured.map(memoryBytes).max() ?? 0
            ForEach(rows.measured) { item in
                let bytes = memoryBytes(item)
                card(item, .running, now: now, share: largest > 0 ? Double(bytes) / Double(largest) : 0,
                     color: layerColor(layer.colorHex))
            }
            if !rows.sessionOnly.isEmpty {
                Text("Active in the last few minutes, with no process here to measure.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(rows.sessionOnly) { item in
                    card(item, .running, now: now, share: 0, color: layerColor(layer.colorHex))
                }
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
        presentation?.isReviewingCleanup = true
        clearReview = ClearReviewRequest(items: items, selection: start, now: now)
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Toolbar

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

    private func card(_ item: WorkItem, _ kind: WorkCard.Kind, now: Date, share: Double, color: Color,
                      cacheBytes: Int64? = nil) -> some View {
        WorkCard(item: item, kind: kind, now: now, isExpanded: expanded.contains(item.id),
                 evidence: store.evidence[BranchesStore.evidenceKey(item)], isDeleting: store.isDeleting,
                 toggle: { toggle(item.id) }, loadEvidence: { store.loadEvidence(for: item) },
                 requestDelete: {
                     presentation?.isReviewingCleanup = true
                     singleReview = DeleteReviewRequest(items: [item])
                 },
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
        Picker("Work status", selection: $page.workStatus) {
            Text("All (\(board.running.count + board.needsLookCount + board.safeToClear.count))").tag(WorkStatusFilter.all)
            Text("Running (\(board.running.count))").tag(WorkStatusFilter.running)
            Text("Needs a look (\(board.needsLookCount))").tag(WorkStatusFilter.needsLook)
            Text("Safe to clear (\(board.safeToClear.count))").tag(WorkStatusFilter.safeToClear)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 680, alignment: .leading)
        .accessibilityLabel("Branch and worktree status")

        if store.snapshot.gitIsMissing {
            LaneEmpty(text: "Git isn't installed. Install the Xcode Command Line Tools to see branches and worktrees here.")
        } else if store.snapshot.repositories.isEmpty, store.snapshot.items.isEmpty,
                  store.snapshot.notCheckedFolders.isEmpty, store.snapshot.activity == .idle {
            LaneEmpty(text: "No repositories yet. Use Add Folder in Settings → Workspace, or work in a repository with an AI tool.")
        } else {
            switch page.workStatus {
            case .all:
                if !board.running.isEmpty { runningRows(board, now: now) }
                if board.needsLookCount > 0 { needsLookRows(board, now: now) }
                if !board.safeToClear.isEmpty { safeToClearRows(board, now: now) }
                if board.running.isEmpty && board.needsLookCount == 0 && board.safeToClear.isEmpty {
                    LaneEmpty(text: "No branches or worktrees match this view.")
                }
            case .running:
                runningRows(board, now: now)
            case .needsLook:
                needsLookRows(board, now: now)
            case .safeToClear:
                safeToClearRows(board, now: now)
            }
        }
    }

    @ViewBuilder
    private func runningRows(_ board: BranchesBoard, now: Date) -> some View {
        HStack(spacing: 6) {
            Text("Running").font(.headline)
            Text("\(board.running.count)").foregroundStyle(.secondary)
        }
        if board.running.isEmpty {
            LaneEmpty(text: "No repository work is running in this view.")
        }
        ForEach(board.running) { item in
            card(item, .running, now: now, share: 0, color: .green)
        }
    }

    @ViewBuilder
    private func needsLookRows(_ board: BranchesBoard, now: Date) -> some View {
        let largest = board.needsLook.map(\.bytes).max() ?? 0
        let color = layerColor(0xE2729A)
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
    }

    @ViewBuilder
    private func safeToClearRows(_ board: BranchesBoard, now: Date) -> some View {
        let largest = board.safeFolders.compactMap(\.size?.totalBytes).max() ?? 0
        let color = layerColor(0xE2729A)
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

    private var clearing: BranchesStore.CleanupProgress? { store.cleanupProgress }

    private var defaultCount: Int {
        ClearSelection(items: board.safeToClear, now: now).chosen.count
    }

    private var headline: String {
        if let clearing {
            return clearing.isStopping ? "Stopping after the current item…"
                : "\(clearing.operation == .restoring ? "Restoring" : "Clearing") \(min(clearing.completed + 1, clearing.total)) of \(clearing.total)…"
        }
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
            Button(clearing?.isStopping == true ? "Stopping…" : "Stop After Current Item") { store.stopDeleting() }
                .disabled(clearing?.isStopping == true || clearing?.operation == .restoring)
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
struct ClearReviewSheet: View {
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
