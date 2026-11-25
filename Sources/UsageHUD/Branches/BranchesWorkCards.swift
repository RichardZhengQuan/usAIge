import AppKit
import SwiftUI

/// A thin separator keeps rows quiet under the scene while details unfold.
@available(macOS 14.0, *)
private struct CardSurface: ViewModifier {
    var isExpanded = false
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        if style == .modern {
            // Grouped-list rows: the separator starts where the text does.
            content
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isExpanded ? Color.primary.opacity(0.03) : .clear)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                        .padding(.leading, ModernMetrics.separatorInset)
                }
        } else {
            content
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isExpanded ? Color.primary.opacity(0.025) : .clear)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
                }
        }
    }
}

// MARK: Cards

/// One branch or worktree: what the work was, which branch, why it can or
/// can't go, and, opened, exactly what it holds.
@available(macOS 14.0, *)
struct WorkCard: View {
    enum Kind: Equatable {
        case running
        case look
        /// Merged or empty work that can be reviewed for clearing.
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
    var tubeShare: Double = 0
    var tubeColor: Color = .orange
    var cacheBytes: Int64? = nil
    @State private var copied = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.rowShowsProject) private var showsProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Unfolded" : "Folded")
                .accessibilityHint(isExpanded ? "Hides the details" : "Shows what it holds")
            if isExpanded {
                Divider().padding(.vertical, 9)
                details
                    .padding(.leading, style == .modern ? ModernMetrics.separatorInset - 14 : 0)
                    .transition(.opacity)
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
    }

    @ViewBuilder
    private var summary: some View {
        if style == .modern {
            HStack(alignment: .top, spacing: 10) {
                let mark = BoardRowMark.mark(for: item, kind: kind)
                ModernIcon(symbol: mark.symbol, color: mark.color)
                    .padding(.top, 1)
                modernSummaryText
                if let trailing = modernTrailing {
                    Text(trailing)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.top, 1)
                }
                FoldChevron(isExpanded: isExpanded)
            }
            .contentShape(Rectangle())
        } else {
            HStack(alignment: .top, spacing: 6) {
                summaryText
                FoldChevron(isExpanded: isExpanded)
            }
            .contentShape(Rectangle())
        }
    }

    /// Two quiet lines: what the work is, then where it is and when it was
    /// used. A third, coloured line appears only when something needs you.
    private var modernSummaryText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.workTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(isExpanded ? 4 : 1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: isExpanded)
            Text(modernSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let cacheSummary {
                Text(cacheSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(cacheSummary)
            }
            if let reason = BoardText.reason(item) {
                Text(reason.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(reason.isLoss ? Color.red : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var modernSubtitle: String {
        var parts = showsProject ? [item.repositoryName] : []
        parts.append(item.branch ?? "no branch")
        if kind == .running {
            parts.append(item.status == .mainCopy ? "main copy" : BoardText.running(item, now: now))
        } else if let used = item.lastUsedAt {
            parts.append("used " + BoardText.age(used, now: now))
        }
        return parts.joined(separator: " · ")
    }

    /// Size or memory sits on the right, as in a Settings list.
    private var modernTrailing: String? {
        if kind == .running {
            var seen: Set<Int32> = []
            let memory = item.processes.reduce(UInt64(0)) { $0 + (seen.insert($1.id).inserted ? $1.memoryBytes : 0) }
            return memory > 0 ? LiveWorkText.memory(memory) : nil
        }
        if let cacheBytes { return BoardText.bytes(cacheBytes) }
        return item.worktreePath == nil ? nil : BoardText.size(item)
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
            PaperweightRowBar(share: tubeShare, color: tubeColor)
                .padding(.vertical, 2)
            if let cacheSummary {
                Text(cacheSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(cacheSummary)
            }
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

    private var cacheSummary: String? {
        guard let cacheBytes else { return nil }
        let names = (item.size?.cacheBytesByName ?? [:]).sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.map { "\($0.key) \(BoardText.bytes($0.value))" }
        return "\(BoardText.bytes(cacheBytes)) cache" + (names.isEmpty ? "" : " · " + names.joined(separator: ", "))
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { actionButtons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { actionButtons }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var actionButtons: some View {
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

/// The lane's water already moves, so this status mark needs no clock.
@available(macOS 14.0, *)
private struct RunningDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

@available(macOS 14.0, *)
struct LeftoverCopyCard<Content: View>: View {
    let copy: LeftoverCopy
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void
    var tubeShare: Double = 0
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                if style == .modern {
                    ModernIcon(symbol: "square.stack.3d.up", color: copy.unsavedCount > 0 ? .red : .orange).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(copy.items.count) \(copy.items.count == 1 ? "branch" : "branches and worktrees") in an older copy of \(copy.projectName)")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if style == .classic {
                        PaperweightRowBar(share: tubeShare, color: StorageCategory.worktrees.tint)
                            .padding(.vertical, 2)
                    }
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
                }
                .padding(.trailing, 28)
                .overlay(alignment: .topTrailing) { FoldChevron(isExpanded: isExpanded) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Unfolded" : "Folded")
            if isExpanded {
                Divider().padding(.vertical, 9)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Another copy of \(copy.projectName) is newer, and nobody has used this one for a week. Keep what matters from these, then the copy can go.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { actions }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 6) { actions }
                    }
                    .controlSize(.small)
                    content()
                }
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
    }

    @ViewBuilder
    private var actions: some View {
        Button("Show in Finder") { FolderActions.showInFinder(copy.repository.folder) }
        Button("Open in Terminal") { FolderActions.openInTerminal(copy.repository.folder) }
    }
}

@available(macOS 14.0, *)
struct UnscannedProjectRow: View {
    let folder: String
    @ObservedObject var store: BranchesStore
    var openClean: (() -> Void)? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        let name = (folder as NSString).lastPathComponent
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(BranchesPresentation.abbreviated(folder))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                switch store.projectAccessFailures[folder] {
                case .denied:
                    Text("Enable access in System Settings → Privacy & Security → Files & Folders, then retry.", bundle: AppLanguage.resourceBundle)
                        .font(.callout)
                case .unavailable:
                    Text("This project folder is unavailable.", bundle: AppLanguage.resourceBundle)
                        .font(.callout)
                default: EmptyView()
                }
            }
            Spacer(minLength: 8)
            if let openClean {
                Button(action: openClean) {
                    Text("Open Clean", bundle: AppLanguage.resourceBundle)
                }
            } else if store.requestingProject == folder {
                ProgressView { Text("Waiting for macOS", bundle: AppLanguage.resourceBundle) }
                    .controlSize(.small)
            } else {
                Button { store.scanProject(folder) } label: {
                    Text("Scan Project", bundle: AppLanguage.resourceBundle)
                }
                .disabled(store.isDeleting || store.requestingProject != nil)
                .accessibilityLabel(AppLanguage.format("Scan %@", locale: locale, name))
                .accessibilityHint(BranchesPresentation.abbreviated(folder))
            }
        }
        .modifier(CardSurface())
    }
}

@available(macOS 14.0, *)
struct ProjectScanSection: View {
    @ObservedObject var store: BranchesStore
    @State private var showsAll = false
    @Environment(\.locale) private var locale

    var body: some View {
        let folders = store.snapshot.notCheckedFolders
        let limit = 3
        ModernSection(title: "Project Folders") {
            Button {
                store.chooseFolder(forScan: true)
            } label: {
                Text("Add Folder…", bundle: AppLanguage.resourceBundle)
            }
            .disabled(store.isDeleting || store.requestingProject != nil)
        } content: {
            ModernNoteRow(text: folders.isEmpty
                          ? "Add a project folder to include it in this scan."
                          : "Scan a project to include it here. macOS may ask for folder access.",
                          symbol: folders.isEmpty ? "folder" : "lock")
            ForEach(folders.prefix(showsAll ? folders.count : limit), id: \.self) { folder in
                UnscannedProjectRow(folder: folder, store: store)
            }
            if folders.count > limit {
                Button {
                    showsAll.toggle()
                } label: {
                    Text(showsAll ? AppLanguage.text("Show less", locale: locale)
                         : AppLanguage.format("Show all %lld", locale: locale, folders.count))
                }
                .buttonStyle(.link)
                .padding(.horizontal, ModernMetrics.rowPadding)
                .padding(.vertical, 8)
            }
        }
        .environment(\.interfaceStyle, .modern)
    }
}

@available(macOS 14.0, *)
struct UnreadableCard: View {
    let repository: RepositoryInfo
    var isExpanded = false
    var toggle: () -> Void = {}
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                if style == .modern {
                    ModernIcon(symbol: "questionmark.folder.fill", color: .orange).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name)
                        .font(.system(size: 13, weight: .semibold))
                    if style == .classic {
                        PaperweightRowBar(share: 0, color: StorageCategory.worktrees.tint)
                            .padding(.vertical, 2)
                    }
                    Text(BranchesPresentation.abbreviated(repository.folder))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 28)
                .overlay(alignment: .topTrailing) { FoldChevron(isExpanded: isExpanded) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Unfolded" : "Folded")
            .accessibilityHint(isExpanded ? "Hides the details" : "Shows why it couldn't be read")
            if isExpanded {
                Divider().padding(.vertical, 9)
                Text(repository.failure ?? "Git couldn't read this repository.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(CardSurface(isExpanded: isExpanded))
    }
}

/// The rows with no folder to show one by one, as a single card.
@available(macOS 14.0, *)
struct SafeGroupCard<Content: View>: View {
    let group: ClearGroup
    let items: [WorkItem]
    let isExpanded: Bool
    let isDeleting: Bool
    let toggle: () -> Void
    let review: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                if style == .modern {
                    ModernIcon(symbol: group == .records ? "doc.text" : "arrow.triangle.branch", color: .gray).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(items.count) \(group.title.prefix(1).lowercased() + group.title.dropFirst())")
                        .font(.system(size: 13, weight: .semibold))
                    if style == .classic {
                        PaperweightRowBar(share: 0, color: StorageCategory.worktrees.tint)
                            .padding(.vertical, 2)
                    }
                    Text(group.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 28)
                .overlay(alignment: .topTrailing) { FoldChevron(isExpanded: isExpanded) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Unfolded" : "Folded")
            if isExpanded {
                Divider().padding(.vertical, 9)
                VStack(alignment: .leading, spacing: 5) {
                    content()
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

