import AppKit
import SwiftUI

/// Keeps hover tracking active while another app owns the key window.
private struct RailHoverTracking: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        view.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: view, userInfo: nil))
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        // The SwiftUI button underneath continues to handle clicks and drags.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
    }
}

@available(macOS 14.0, *)
struct RailDetailHover: ViewModifier {
    @Binding var isHovered: Bool
    let changed: (Bool, CGRect) -> Void
    @State private var rowFrame = CGRect.zero

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            rowFrame = frame
            if isHovered { changed(true, frame) }
        }
        .background(RailHoverTracking { inside in
            isHovered = inside
            changed(inside, rowFrame)
        })
        .onDisappear { changed(false, rowFrame) }
    }
}

/// Where the hovered row's detail card sits: beside the rail on the right
/// when it fits and on the left otherwise, centred on the row and on screen,
/// with its arrow pointing back at the row.
@available(macOS 14.0, *)
struct QuotaDetailPlacement: Equatable {
    /// Leaves room for the arrow, whose tip stops just short of the rail.
    static let gap = QuotaDetailCardShape.arrowLength + 1

    let cardFrame: CGRect
    let arrowEdge: HorizontalEdge
    let arrowOffset: CGFloat

    init(cardSize size: CGSize, rail: CGRect, rowMidY: CGFloat, visibleFrame: CGRect) {
        let rightX = rail.maxX + Self.gap
        let fitsOnRight = rightX + size.width <= visibleFrame.maxX
        let x = fitsOnRight ? rightX : rail.minX - Self.gap - size.width
        let y = rowMidY - size.height / 2
        cardFrame = CGRect(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
        arrowEdge = fitsOnRight ? .leading : .trailing
        // Screen coordinates grow upward; the card's view coordinates grow downward.
        arrowOffset = cardFrame.midY - rowMidY
    }
}

/// Shows the hovered row's details in one panel kept for the life of the app.
///
/// SwiftUI's `.popover` can't be used here: on macOS 26 each new `NSPopover`
/// leaves its glass view and GPU surface behind when it closes, which adds up
/// to hundreds of megabytes on a rail that opens one for every hover.
@available(macOS 14.0, *)
@MainActor
final class QuotaDetailPanelController {
    /// How long a card waits after the pointer leaves, so it can cross to it.
    static let hideDelay: TimeInterval = 0.25
    private static let pointerPollInterval: TimeInterval = 0.05

    private let railWindow: () -> NSWindow?
    private let pointerLocation: () -> CGPoint
    private var hostingView: NSHostingView<AppLanguageEnvironment<RailDetailCard>>?
    private var rowFrame = CGRect.zero
    private var shownQuotaRow: RailQuotaRow?
    private var liveWork = LiveWorkSummary()
    private var memory: SystemMemoryUsage?
    private var arrowEdge: HorizontalEdge = .leading
    private var hideTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    private(set) var panel: NSPanel?
    private(set) var shownRowID: RailDetailID?
    /// True while the pointer is on the card or crossing over to it. A docked
    /// rail has to stay out too: the card is its child window and moves with it.
    private(set) var isPointerOnCard = false
    /// Lets the live work monitor sample faster only while a card can be seen.
    var onVisibilityChanged: ((Bool) -> Void)?
    /// Opens the Branches window, with the given paperweight in front when set.
    var openBranches: (PaperweightID?) -> Void = { _ in }
    var openCPU: () -> Void = {}

    init(
        rail: @escaping () -> NSWindow?,
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        railWindow = rail
        self.pointerLocation = pointerLocation
    }

    /// Shows the limit or tool beside its row, in the rail's coordinates.
    func show(_ row: RailQuotaRow, rowFrame: CGRect) {
        shownRowID = row.id
        shownQuotaRow = row
        presentOnHover(content(for: row), rowFrame: rowFrame)
    }

    /// Shows every tool's current work beside the rail's tile.
    func showLiveWork(rowFrame: CGRect) {
        shownRowID = .liveWork
        shownQuotaRow = nil
        presentOnHover(.liveWork(liveWork, memory: memory), rowFrame: rowFrame)
    }

    func showCPU(rowFrame: CGRect, monitor: SystemCPUMonitor) {
        shownRowID = .cpu
        shownQuotaRow = nil
        presentOnHover(.cpu(monitor), rowFrame: rowFrame)
    }

    /// Shows the disk, and what the Branches window last measured on it,
    /// beside the rail's Storage paperweight.
    func showStorage(rowFrame: CGRect, disk: DiskSpace?, breakdown: StorageBreakdown?) {
        shownRowID = .storage
        shownQuotaRow = nil
        presentOnHover(.storage(disk, breakdown), rowFrame: rowFrame)
    }

    private func presentOnHover(_ content: RailDetailCard.Content, rowFrame: CGRect) {
        self.rowFrame = rowFrame
        // A row's enter can arrive before the timer sees the pointer leave the
        // card. Clear the old card's pointer state before the next poll.
        isPointerOnCard = false
        panel?.ignoresMouseEvents = true
        cancelPendingHide()
        present(content)
        startWatchingPointer()
        // CPU has its own sampler. Opening its card doesn't require a process scan.
        onVisibilityChanged?(shownRowID != .cpu)
    }

    /// Keeps the open card current as the rail's rows change.
    func update(_ rows: [RailQuotaRow]) {
        guard let shownQuotaRow else { return }
        guard let row = rows.first(where: { $0.id == shownQuotaRow.id }) else {
            hide(rowID: shownQuotaRow.id)
            return
        }
        self.shownQuotaRow = row
        present(content(for: row))
    }

    /// Keeps the open card current as the work changes.
    func update(liveWork: LiveWorkSummary, memory: SystemMemoryUsage? = nil) {
        let workChanged = self.liveWork != liveWork
        self.liveWork = liveWork
        self.memory = memory
        if shownRowID == .liveWork {
            present(.liveWork(liveWork, memory: memory))
        } else if workChanged, let shownQuotaRow {
            present(content(for: shownQuotaRow))
        }
    }

    private func content(for row: RailQuotaRow) -> RailDetailCard.Content {
        .quota(
            row.snapshot,
            others: row.otherLimits,
            work: liveWork.sessions(for: row.snapshot.toolID),
            memoryBytes: liveWork.memoryBytes(for: row.snapshot.toolID)
        )
    }

    /// The pointer left this row. The card stays a moment, so the pointer can
    /// cross to it, and goes if the pointer doesn't arrive.
    func pointerLeft(rowID: RailDetailID) {
        guard shownRowID == rowID else { return }
        scheduleHide()
    }

    /// Hides the card if it still belongs to this row. When the pointer moves
    /// between rows, the new row's hover can arrive before the old row's exit.
    func hide(rowID: RailDetailID) {
        guard shownRowID == rowID else { return }
        shownRowID = nil
        shownQuotaRow = nil
        isPointerOnCard = false
        cancelPendingHide()
        stopWatchingPointer()
        onVisibilityChanged?(false)
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// One step of the pointer watch; exposed for tests. The window extends
    /// past the card and over the rail for the shadow, so it takes mouse events
    /// only while the pointer is on the card itself. Tracking areas can't
    /// decide this: they'd need the window to take events first.
    func handlePointer(at pointer: CGPoint) {
        guard shownRowID != nil, let panel, let rail = panel.parent else { return }
        // The child window moves with the rail during a drag or Magnet animation.
        let inset = QuotaDetailCard.windowInset
        let cardFrame = panel.frame.insetBy(dx: inset, dy: inset)
        let railEdge = arrowEdge == .leading ? rail.frame.maxX : rail.frame.minX
        let minX = min(railEdge, cardFrame.minX)
        let keepOpenFrame = CGRect(
            x: minX,
            y: cardFrame.minY,
            width: max(railEdge, cardFrame.maxX) - minX,
            height: cardFrame.height
        )
        panel.ignoresMouseEvents = !cardFrame.contains(pointer)
        if keepOpenFrame.contains(pointer) {
            isPointerOnCard = true
            cancelPendingHide()
        } else if isPointerOnCard {
            isPointerOnCard = false
            scheduleHide()
        }
    }

    private func scheduleHide() {
        cancelPendingHide()
        guard !isPointerOnCard, let id = shownRowID else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hideDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isPointerOnCard else { return }
            self.hide(rowID: id)
        }
    }

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func startWatchingPointer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerPollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Added to the main run loop below, so this runs on the main thread.
            MainActor.assumeIsolated {
                self.handlePointer(at: self.pointerLocation())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopWatchingPointer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    /// A paperweight's own card opens Branches with that paperweight in front;
    /// a usage card leaves whichever one is already there.
    func openShownDetails() {
        guard let id = shownRowID else { return }
        hide(rowID: id)
        switch id {
        case .cpu: openCPU()
        case .storage: openBranches(.storage)
        case .liveWork: openBranches(.memory)
        case .limit, .tool: openBranches(nil)
        }
    }

    private func present(_ content: RailDetailCard.Content) {
        guard let rail = railWindow(), let railView = rail.contentView else { return }
        let cardView = cardView(showing: content)
        let panel = self.panel ?? makePanel(contentView: cardView)
        self.panel = panel

        let inset = QuotaDetailCard.windowInset
        let fittingSize = cardView.fittingSize
        let rowOnScreen = rail.convertToScreen(railView.convert(rowFrame, to: nil))
        let screen = rail.screen ?? NSScreen.main
        let placement = QuotaDetailPlacement(
            cardSize: CGSize(width: fittingSize.width - inset * 2, height: fittingSize.height - inset * 2),
            rail: rail.frame,
            rowMidY: rowOnScreen.midY,
            visibleFrame: screen?.visibleFrame ?? rail.frame
        )
        cardView.rootView = RailDetailCard(
            content: content,
            arrowEdge: placement.arrowEdge,
            arrowOffset: placement.arrowOffset,
            openDetails: { [weak self] in self?.openShownDetails() }
        ).appLanguageEnvironment()
        arrowEdge = placement.arrowEdge
        panel.setFrame(placement.cardFrame.insetBy(dx: -inset, dy: -inset), display: true)
        panel.level = rail.level
        // As a child window the card follows the rail when it is dragged.
        if panel.parent == nil {
            rail.addChildWindow(panel, ordered: .above)
            if rail.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func cardView(showing content: RailDetailCard.Content) -> NSHostingView<AppLanguageEnvironment<RailDetailCard>> {
        let card = RailDetailCard(content: content, openDetails: { [weak self] in self?.openShownDetails() })
        if let hostingView {
            hostingView.rootView = card.appLanguageEnvironment()
            return hostingView
        }
        let view = NSHostingView(rootView: card.appLanguageEnvironment())
        hostingView = view
        return view
    }

    private func makePanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 376, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Until the pointer is on the card itself, so its margin can't take
        // hover from the rail.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = HUDPanel.overlayCollectionBehavior
        return panel
    }
}
