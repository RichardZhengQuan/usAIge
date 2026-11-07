import AppKit
import SwiftUI

/// The Branches window: how full the disk is and what clearing would free,
/// then every branch and worktree sorted by what to do about it.
@available(macOS 14.0, *)
struct BranchesRootView: View {
    private enum Section: Hashable { case work, storage }

    @ObservedObject var store: BranchesStore
    var liveWork: LiveWorkMonitor?
    @State private var section = Section.work
    @State private var query = ""
    @State private var projectID: String?
    @State private var clearReview: ClearReviewRequest?
    @State private var expanded: Set<String> = []
    @State private var singleReview: DeleteReviewRequest?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let now = Date()
        let everything = BranchesBoard.make(snapshot: store.snapshot, now: now)
        let shown = BranchesBoard.make(snapshot: store.snapshot, query: query, projectID: projectID, now: now)
        let picks = ClearSelection(items: everything.safeToClear, now: now)
        VStack(spacing: 0) {
            BranchesHero(
                store: store,
                board: everything,
                pickedBytes: picks.bytes(from: everything.safeToClear),
                pickedCount: picks.chosenItems(from: everything.safeToClear).count,
                isReviewing: clearReview != nil,
                now: now,
                review: { startReview(everything.safeToClear, now: now) }
            )
            Divider()
            toolbar(projects: everything.projects)
            Divider()
            Group {
                switch section {
                case .work:
                    work(shown: shown, everything: everything, now: now)
                case .storage:
                    ToolStorageView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = store.resultMessage, message.deletedCount == 0 {
                Divider()
                ResultBanner(message: message, store: store)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onChange(of: section) { _, value in
            if value == .storage, store.toolStorage.isEmpty { store.loadToolStorage() }
        }
        .onChange(of: projectID) { _, value in
            if let value, !everything.projects.contains(where: { $0.id == value }) { projectID = nil }
        }
        .sheet(item: $singleReview) { request in
            DeleteReviewView(request: request) { chosen in
                singleReview = nil
                store.startDelete(chosen)
            } cancel: {
                singleReview = nil
            }
        }
        .sheet(item: $clearReview) { request in
            ClearReviewSheet(request: request, disk: store.diskSpace) { chosen in
                clearReview = nil
                expanded = []
                store.startDelete(chosen)
            } cancel: {
                clearReview = nil
            }
        }
    }

    /// The review works on the rows as they were when it opened, so a scan
    /// finishing meanwhile can't move them under the pointer. Each one is
    /// checked again before it goes anyway.
    private func startReview(_ items: [WorkItem], now: Date, only group: ClearGroup? = nil) {
        var start = ClearSelection(items: items, now: now)
        if let group {
            start.chosen = Set(items.filter { ClearGroup.group(for: $0, now: now) == group }.map(\.id))
        }
        store.resultMessage = nil
        clearReview = ClearReviewRequest(items: items, selection: start, now: now)
    }

    // MARK: Toolbar

    private func toolbar(projects: [ProjectChoice]) -> some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $section) {
                Text("Work").tag(Section.work)
                Text("Tool storage").tag(Section.storage)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            if section == .work {
                searchField
                if projects.count > 1 { projectChips(projects) }
            }
            Spacer(minLength: 8)
            activityView
            recentlyDeletedMenu
            Menu {
                Button("Read Everything Again") {
                    if section == .storage { store.loadToolStorage(force: true) } else { store.refresh() }
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
        .fixedSize(horizontal: true, vertical: false)
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

    // MARK: Work

    @ViewBuilder
    private func work(shown: BranchesBoard, everything: BranchesBoard, now: Date) -> some View {
        if store.snapshot.gitIsMissing {
            ContentUnavailableView(
                "Git isn't installed",
                systemImage: "arrow.triangle.branch",
                description: Text("Install the Xcode Command Line Tools to see branches and worktrees here.")
            )
        } else if store.snapshot.items.isEmpty, store.snapshot.notCheckedFolders.isEmpty, store.snapshot.activity == .idle {
            ContentUnavailableView(
                "No repositories yet",
                systemImage: "arrow.triangle.branch",
                description: Text("Repositories appear here once an AI tool has worked in them, or use Add Folder in the … menu.")
            )
        } else {
            HStack(alignment: .top, spacing: 12) {
                runningLane(shown, now: now)
                lookLane(shown, now: now)
                safeLane(shown, everything: everything, now: now)
            }
            .padding(14)
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func card(_ item: WorkItem, _ kind: WorkCard.Kind, now: Date) -> some View {
        WorkCard(
            item: item,
            kind: kind,
            now: now,
            isExpanded: expanded.contains(item.id),
            evidence: store.evidence[BranchesStore.evidenceKey(item)],
            isDeleting: store.isDeleting,
            toggle: { toggle(item.id) },
            loadEvidence: { store.loadEvidence(for: item) },
            requestDelete: { singleReview = DeleteReviewRequest(items: [item]) }
        )
    }

    private func runningLane(_ board: BranchesBoard, now: Date) -> some View {
        LaneColumn(
            title: "Running now",
            count: board.running.count,
            subtitle: board.running.isEmpty ? "Nothing running in your repositories" : "Leave these alone",
            accessory: { if let liveWork { LaneMemoryTank(monitor: liveWork) } }
        ) {
            if board.running.isEmpty {
                LaneEmpty(text: "When an AI tool or a dev server runs in a worktree, it shows here.")
            }
            ForEach(board.running) { item in card(item, .running, now: now) }
        }
    }

    private func lookLane(_ board: BranchesBoard, now: Date) -> some View {
        let bytes = board.needsLookBytes
        return LaneColumn(
            title: "Needs a look",
            count: board.needsLookCount,
            subtitle: board.needsLook.isEmpty ? "Nothing is waiting on you"
                : bytes > 0 ? "\(BoardText.bytes(bytes)) waiting on you" : "Waiting on you",
            accessory: { EmptyView() }
        ) {
            if board.needsLook.isEmpty {
                LaneEmpty(text: "Work that exists only on this Mac, or isn't on main yet, shows here.")
            }
            ForEach(board.needsLook) { entry in
                switch entry {
                case let .item(item):
                    card(item, .look, now: now)
                case let .copy(copy):
                    LeftoverCopyCard(copy: copy, now: now, isExpanded: expanded.contains(entry.id), toggle: { toggle(entry.id) }) {
                        ForEach(copy.items) { item in card(item, .look, now: now) }
                    }
                case let .notChecked(folder):
                    NotCheckedCard(folder: folder, isExpanded: expanded.contains(entry.id), toggle: { toggle(entry.id) }) {
                        store.addFolder(folder)
                    }
                case let .unreadable(repository):
                    UnreadableCard(repository: repository)
                }
            }
            if board.stillChecking > 0 {
                Text("Still checking \(board.stillChecking) more…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func safeLane(_ board: BranchesBoard, everything: BranchesBoard, now: Date) -> some View {
        let bytes = board.safeBytes
        let folders = board.safeFolders
        let largest = folders.compactMap(\.size?.totalBytes).max() ?? 0
        return LaneColumn(
            title: "Safe to clear",
            count: board.safeToClear.count,
            subtitle: board.safeToClear.isEmpty ? "Nothing to clear"
                : bytes > 0 ? "\(BoardText.bytes(bytes)), nothing to lose" : "Nothing to lose",
            accessory: {
                // Reviews exactly what the column shows, so a search or a
                // project narrows what's offered.
                if !board.safeToClear.isEmpty {
                    Button("Clear…") { startReview(board.safeToClear, now: now) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(store.isDeleting)
                        .help("Review the \(board.safeToClear.count) shown here, then clear them")
                }
            }
        ) {
            if board.safeToClear.isEmpty {
                LaneEmpty(text: "Merged or empty branches and worktrees that nothing runs in show here.")
            }
            ForEach(folders) { item in
                card(item, .safe(fill: largest > 0 ? Double(item.size?.totalBytes ?? 0) / Double(largest) : 0), now: now)
            }
            ForEach([ClearGroup.branches, .records]) { group in
                let items = board.safe(in: group, now: now)
                if !items.isEmpty {
                    SafeGroupCard(
                        group: group,
                        items: items,
                        isExpanded: expanded.contains("group|" + group.rawValue),
                        isDeleting: store.isDeleting,
                        toggle: { toggle("group|" + group.rawValue) },
                        review: { startReview(everything.safeToClear, now: now, only: group) }
                    )
                }
            }
        }
    }
}

// MARK: Hero

/// The disk as a tank, and the one thing worth doing about it.
@available(macOS 14.0, *)
private struct BranchesHero: View {
    @ObservedObject var store: BranchesStore
    let board: BranchesBoard
    let pickedBytes: Int64
    let pickedCount: Int
    let isReviewing: Bool
    let now: Date
    let review: () -> Void

    private var disk: DiskSpace? { store.diskSpace }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            DiskTank(disk: disk, freeing: pickedBytes)
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                if let problems {
                    Text(problems)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                actions.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .animation(.snappy, value: headline)
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
        HStack(spacing: 8) {
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
            }
        }
        .controlSize(.large)
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
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var now: Double { disk?.usedShare() ?? 0 }
    private var after: Double { disk?.usedShare(freeing: freeing) ?? 0 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 20 : 26, style: .continuous) }

    var body: some View {
        let color = LiveWorkText.severity(now).color
        // Moving water is for the window being looked at, not left behind.
        let moves = activeState == .key && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !moves)) { context in
            let phase = moves ? context.date.timeIntervalSinceReferenceDate * 1.4 : 0.6
            ZStack {
                WaterShape(level: now, phase: phase + 1.7, amplitude: 2.5, wavelength: 70)
                    .fill(color.opacity(0.24))
                WaterShape(level: after, phase: phase, amplitude: 2.5, wavelength: 70)
                    .fill(color.opacity(0.5))
            }
            .animation(.easeInOut(duration: 1.1), value: after)
            .animation(.easeInOut(duration: 1.1), value: now)
        }
        .clipShape(shape)
        .overlay {
            VStack(spacing: 0) {
                // The tank shows the disk after the ticked items go, so the
                // number does too.
                Text(disk == nil ? "–" : LiveWorkText.percent(compact ? after : now))
                    .font(.system(size: compact ? 20 : 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: after)
                Text(compact ? "after" : "disk used")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.7))
            }
        }
        .frame(width: compact ? 78 : 104, height: compact ? 98 : 132)
        .background { BoardGlass(shape: shape) }
        .overlay { shape.stroke(Color.primary.opacity(0.16), lineWidth: 1) }
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

/// The rail's glass where macOS has it, and its material where it doesn't.
@available(macOS 14.0, *)
private struct BoardGlass<S: Shape>: View {
    let shape: S

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

/// The share of memory the AI tools use, as the rail's tile shows it.
@available(macOS 14.0, *)
private struct LaneMemoryTank: View {
    @ObservedObject var monitor: LiveWorkMonitor
    var physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        let share = LiveWorkText.memoryShare(monitor.summary.memoryBytes, of: physicalMemory)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(spacing: -1) {
            Text(LiveWorkText.percent(share))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("Memory")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .frame(width: 52, height: 36)
        .background {
            ZStack {
                BoardGlass(shape: shape)
                WaterLevelView(level: LiveWorkText.waterLevel(share), color: LiveWorkText.severity(share).color, isMoving: false)
                    .clipShape(shape)
                shape.stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
        }
        .help(LiveWorkText.tileHelp(monitor.summary, of: physicalMemory))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue(LiveWorkText.memorySentence(monitor.summary.memoryBytes, of: physicalMemory))
    }
}

// MARK: Lanes

@available(macOS 14.0, *)
private struct LaneColumn<Accessory: View, Content: View>: View {
    let title: String
    let count: Int
    let subtitle: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.headline)
                        if count > 0 {
                            Text("\(count)")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                accessory()
            }
            .frame(minHeight: 38)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

/// A card's surface: the window's content colour with a hairline edge.
@available(macOS 14.0, *)
private struct CardSurface: ViewModifier {
    var isExpanded = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isExpanded ? 0.22 : 0.1), lineWidth: 1)
            }
    }
}

// MARK: Cards

/// One branch or worktree: what the work was, which branch, why it can or
/// can't go, and, opened, exactly what it holds.
@available(macOS 14.0, *)
private struct WorkCard: View {
    enum Kind: Equatable {
        case running
        case look
        /// `fill` is its size against the column's largest, drawn as water.
        case safe(fill: Double)
    }

    let item: WorkItem
    let kind: Kind
    let now: Date
    let isExpanded: Bool
    let evidence: WorkEvidence?
    let isDeleting: Bool
    let toggle: () -> Void
    let loadEvidence: () -> Void
    let requestDelete: () -> Void
    @State private var copied = false

    private var waterFill: Double {
        if case let .safe(fill) = kind { return fill }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Hides the details" : "Shows what it holds")
            if isExpanded {
                Divider().padding(.vertical, 9)
                details
                    .transition(.opacity)
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
        .background {
            if waterFill > 0 {
                GeometryReader { proxy in
                    Color.green.opacity(0.11)
                        .frame(height: max(4, proxy.size.height * min(waterFill, 1)))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 6) {
            summaryText
            FoldChevron(isExpanded: isExpanded)
        }
        .contentShape(Rectangle())
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 3) {
            if kind == .running {
                HStack(spacing: 6) {
                    RunningDot()
                    Text(BoardText.running(item, now: now))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)
            }
            Text(item.workTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(isExpanded ? 4 : 2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(branchLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let reason = BoardText.reason(item) {
                Text(reason.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reason.isLoss ? Color.red : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                ToolMarks(tools: item.sessions.tools)
                Text(kind == .running ? runningMeta : BoardText.meta(item, now: now))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var branchLine: String {
        "\(item.repositoryName) · \(item.branch ?? "no branch")"
    }

    private var runningMeta: String {
        var parts: [String] = []
        let memory = item.processes.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        if memory > 0 { parts.append("\(LiveWorkText.memory(memory)) memory") }
        if item.worktreePath != nil, item.status != .mainCopy { parts.append(BoardText.size(item)) }
        if item.status == .mainCopy { parts.append("Main copy") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch kind {
            case .running:
                runningDetails
            case .look:
                evidenceDetails
                explanation
            case .safe:
                explanation
            }
            sessionsLine
            if let path = item.worktreePath {
                Text(BranchesPresentation.abbreviated(path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .help(path)
            }
            actions
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runningDetails: some View {
        if !item.processes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(item.processes) { process in
                    Text(processLine(process))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        Text(item.status == .mainCopy
             ? "This is the repository's main copy, so it stays."
             : "Delete comes back once nothing runs here.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func processLine(_ process: WorkProcess) -> String {
        var parts = [process.name]
        if !process.ports.isEmpty { parts.append("port " + process.ports.map(String.init).joined(separator: ", ")) }
        parts.append(LiveWorkText.memory(process.memoryBytes))
        if let started = process.startedAt { parts.append("since \(BranchesPresentation.relativeTime(started, now: now))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var evidenceDetails: some View {
        let hasCommits = (item.facts.commitsAtRisk ?? 0) > 0 || item.status == .pushed
        let hasFiles = (item.facts.changedFiles ?? 0) + (item.facts.untrackedFiles ?? 0) > 0
        if hasCommits || hasFiles {
            if let evidence {
                if !evidence.commits.isEmpty {
                    evidenceList(
                        title: (item.facts.commitsAtRisk ?? 0) > 0 ? "Commits only on this Mac" : "Commits not on main yet",
                        lines: evidence.commits,
                        more: evidence.moreCommits,
                        monospaced: false
                    )
                }
                if !evidence.files.isEmpty {
                    evidenceList(title: "Files not committed", lines: evidence.files, more: evidence.moreFiles, monospaced: true)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading what it holds…").font(.caption).foregroundStyle(.secondary)
                }
                .onAppear(perform: loadEvidence)
            }
        }
    }

    private func evidenceList(title: String, lines: [String], more: Int, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(monospaced ? .system(size: 11, design: .monospaced) : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if more > 0 {
                Text("and \(more) more").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.status == .finished || item.status == .empty ? sentence(item.workSummary) : item.statusExplanation)
                .fixedSize(horizontal: false, vertical: true)
            if let size = item.size, size.cacheBytes > 0 {
                let names = size.cacheBytesByName.sorted { $0.value > $1.value }.prefix(3).map(\.key)
                Text("\(BoardText.bytes(size.cacheBytes)) of it is cache a build makes again: \(names.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.losesIgnoredFiles {
                Text("Ignored files that would be lost: " + item.irreplaceableIgnored.prefix(5).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.facts.isLocked, let reason = item.facts.lockReason, !reason.isEmpty {
                Text("Lock note: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }

    @ViewBuilder
    private var sessionsLine: some View {
        let sessions = item.sessions
        if sessions.count > 0 {
            let latest = sessions.lastActiveAt.map { ", latest \(BranchesPresentation.relativeTime($0, now: now))" } ?? ""
            Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions") from \(sessions.tools.joined(separator: ", "))\(latest)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let path = item.worktreePath, item.facts.folderExists, item.facts.folderReadable {
                Button("Show in Finder") { FolderActions.showInFinder(path) }
                Button("Open in Terminal") { FolderActions.openInTerminal(path) }
            }
            switch item.eligibility {
            case .allowed:
                Button("Delete…", role: .destructive, action: requestDelete)
                    .disabled(isDeleting)
                if let commands = item.commandsToRun {
                    Button(copied ? "Copied" : "Copy Commands") {
                        FolderActions.copy(commands)
                        copied = true
                    }
                    .help(commands)
                }
            case .blocked:
                if let path = item.worktreePath {
                    Button("Copy Path") { FolderActions.copy(path) }
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}

/// Small marks for the AI tools that worked on a row.
@available(macOS 14.0, *)
private struct ToolMarks: View {
    let tools: [String]

    private var descriptors: [AIToolDescriptor] {
        tools.compactMap { name -> AIToolDescriptor? in
            switch name {
            case "Claude Code": .descriptor(for: .claude)
            case "Codex": .descriptor(for: .chatGPT)
            case "Cursor": .descriptor(for: .cursor)
            case "Grok Build": .descriptor(for: .grok)
            default: nil
            }
        }
    }

    var body: some View {
        if !descriptors.isEmpty {
            HStack(spacing: 2) {
                ForEach(descriptors) { tool in
                    AIToolIcon(tool: tool, size: 11)
                        .help(tool.name)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Worked on by " + tools.joined(separator: ", "))
        }
    }
}

/// Breathes while the window is in front, and holds still otherwise.
@available(macOS 14.0, *)
private struct RunningDot: View {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moves = activeState == .key && !reduceMotion
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .phaseAnimator(moves ? [1.0, 0.35] : [1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
            .accessibilityHidden(true)
    }
}

@available(macOS 14.0, *)
private struct LeftoverCopyCard<Content: View>: View {
    let copy: LeftoverCopy
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(copy.items.count) \(copy.items.count == 1 ? "branch" : "branches and worktrees") in an older copy of \(copy.projectName)")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(BranchesPresentation.abbreviated(copy.repository.folder))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if copy.unsavedCount > 0 {
                        Text("\(copy.unsavedCount) \(copy.unsavedCount == 1 ? "holds" : "hold") work that's only on this Mac")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    } else {
                        Text("Pushed, but not on main yet")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text([copy.lastUsedAt.map { "Last used " + BoardText.age($0, now: now) } ?? "Not used lately",
                          copy.bytes > 0 ? BoardText.bytes(copy.bytes) : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
                .overlay(alignment: .topTrailing) { FoldChevron(isExpanded: isExpanded) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Divider().padding(.vertical, 9)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Another copy of \(copy.projectName) is newer, and nobody has used this one for a week. Keep what matters from these, then the copy can go.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Show in Finder") { FolderActions.showInFinder(copy.repository.folder) }
                        Button("Open in Terminal") { FolderActions.openInTerminal(copy.repository.folder) }
                    }
                    .controlSize(.small)
                    content()
                }
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
    }
}

@available(macOS 14.0, *)
private struct NotCheckedCard: View {
    let folder: String
    let isExpanded: Bool
    let toggle: () -> Void
    let check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: folder).lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                    Text(BranchesPresentation.abbreviated(folder))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Not checked: macOS protects this folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
                .overlay(alignment: .topTrailing) { FoldChevron(isExpanded: isExpanded) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Divider().padding(.vertical, 9)
                VStack(alignment: .leading, spacing: 8) {
                    Text("""
                    usAIge doesn't read folders macOS protects by itself, and macOS may ask for permission. \
                    If iCloud manages the folder, usAIge lists its branches but skips files and sizes, because \
                    reading them can start downloads, so they can't be deleted here.
                    """)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Check This Folder", action: check)
                        .controlSize(.small)
                }
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
    }
}

@available(macOS 14.0, *)
private struct UnreadableCard: View {
    let repository: RepositoryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(repository.name)
                .font(.system(size: 13, weight: .semibold))
            Text(BranchesPresentation.abbreviated(repository.folder))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(repository.failure ?? "Git couldn't read this repository.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .modifier(CardSurface())
    }
}

/// The rows with no folder to show one by one, as a single card.
@available(macOS 14.0, *)
private struct SafeGroupCard: View {
    let group: ClearGroup
    let items: [WorkItem]
    let isExpanded: Bool
    let isDeleting: Bool
    let toggle: () -> Void
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(items.count) \(group.title.prefix(1).lowercased() + group.title.dropFirst())")
                        .font(.system(size: 13, weight: .semibold))
                    Text(group.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
                .overlay(alignment: .topTrailing) { FoldChevron(isExpanded: isExpanded) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Divider().padding(.vertical, 9)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items.prefix(40)) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.workTitle).font(.caption).lineLimit(1)
                            Text(item.branch ?? item.worktreePath.map { BranchesPresentation.abbreviated($0) } ?? "")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if items.count > 40 {
                        Text("and \(items.count - 40) more").font(.caption).foregroundStyle(.tertiary)
                    }
                    Button("Review and Clear These…", action: review)
                        .controlSize(.small)
                        .disabled(isDeleting)
                        .padding(.top, 3)
                }
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
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
private struct FoldChevron: View {
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

// MARK: Tool storage

@available(macOS 14.0, *)
private struct ToolStorageView: View {
    @ObservedObject var store: BranchesStore

    private func tint(_ kind: ToolStorageKind) -> Color {
        switch kind {
        case .rebuildable: .green
        case .history: .orange
        case .runtime: .blue
        case .review: .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("What AI and developer tools keep on this Mac. Shown only: usAIge clears nothing here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isMeasuringToolStorage {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if store.toolStorage.isEmpty {
                ContentUnavailableView(
                    store.isMeasuringToolStorage ? "Measuring…" : "Nothing to show",
                    systemImage: "internaldrive",
                    description: Text("Folders under 10 MB are left out.")
                )
            } else {
                Table(store.toolStorage) {
                    TableColumn("Name") { entry in
                        Text(entry.name).lineLimit(1)
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn("Where") { entry in
                        Text(entry.path.map { BranchesPresentation.abbreviated($0) } ?? "Managed by Xcode")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.path ?? "")
                    }
                    .width(min: 200, ideal: 380)
                    TableColumn("Size") { entry in
                        Text(entry.bytes, format: .byteCount(style: .file))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 80, max: 100)
                    TableColumn("Kind") { entry in
                        Text(entry.kind.label)
                            .font(.caption)
                            .foregroundStyle(tint(entry.kind))
                    }
                    .width(min: 84, ideal: 96, max: 120)
                    TableColumn("") { entry in
                        if let path = entry.path {
                            Button {
                                FolderActions.showInFinder(path)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(entry.name) in Finder")
                            .help("Show in Finder")
                        }
                    }
                    .width(28)
                }
            }
        }
        .onAppear {
            if store.toolStorage.isEmpty { store.loadToolStorage() }
        }
    }
}
