import AppKit
import SwiftUI

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
    /// Stands in for a snapshot's id while the tile's card is showing.
    static let liveWorkID = "usAIge.liveWork"
    /// How long a card waits after the pointer leaves, so it can cross to it.
    static let hideDelay: TimeInterval = 0.25
    private static let pointerPollInterval: TimeInterval = 0.05

    private let railWindow: () -> NSWindow?
    private let pointerLocation: () -> CGPoint
    private var hostingView: NSHostingView<RailDetailCard>?
    private var rowFrame = CGRect.zero
    private var shownSnapshot: QuotaSnapshot?
    private var liveWork = LiveWorkSummary()
    /// The visible card, without the transparent margin around it.
    private var cardFrame = CGRect.zero
    /// The card plus the gap between it and the rail.
    private var keepOpenFrame = CGRect.zero
    private var hideTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    private(set) var panel: NSPanel?
    private(set) var shownSnapshotID: String?
    /// True while the pointer is on the card or crossing over to it. A docked
    /// rail has to stay out too: the card is its child window and moves with it.
    private(set) var isPointerOnCard = false
    /// Lets the live work monitor sample faster only while a card can be seen.
    var onVisibilityChanged: ((Bool) -> Void)?
    var openBranches: () -> Void = {}

    init(
        rail: @escaping () -> NSWindow?,
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        railWindow = rail
        self.pointerLocation = pointerLocation
    }

    /// Shows `snapshot` beside its row. `rowFrame` is in the rail's coordinates.
    func show(_ snapshot: QuotaSnapshot, rowFrame: CGRect) {
        shownSnapshotID = snapshot.id
        shownSnapshot = snapshot
        self.rowFrame = rowFrame
        cancelPendingHide()
        present(content(for: snapshot))
        startWatchingPointer()
        onVisibilityChanged?(true)
    }

    /// Shows every tool's current work beside the rail's tile.
    func showLiveWork(rowFrame: CGRect) {
        shownSnapshotID = Self.liveWorkID
        shownSnapshot = nil
        self.rowFrame = rowFrame
        cancelPendingHide()
        present(.liveWork(liveWork))
        startWatchingPointer()
        onVisibilityChanged?(true)
    }

    /// Keeps the open card current as new usage arrives.
    func update(_ snapshots: [QuotaSnapshot]) {
        guard let shownSnapshotID, shownSnapshotID != Self.liveWorkID else { return }
        if let snapshot = snapshots.first(where: { $0.id == shownSnapshotID }) {
            shownSnapshot = snapshot
            present(content(for: snapshot))
        } else {
            hide(snapshotID: shownSnapshotID)
        }
    }

    /// Keeps the open card current as the work changes.
    func update(liveWork: LiveWorkSummary) {
        self.liveWork = liveWork
        if shownSnapshotID == Self.liveWorkID {
            present(.liveWork(liveWork))
        } else if let shownSnapshot {
            present(content(for: shownSnapshot))
        }
    }

    private func content(for snapshot: QuotaSnapshot) -> RailDetailCard.Content {
        .quota(
            snapshot,
            work: liveWork.sessions(for: snapshot.toolID),
            memoryBytes: liveWork.memoryBytes(for: snapshot.toolID)
        )
    }

    /// The pointer left this row. The card stays a moment, so the pointer can
    /// cross to it, and goes if the pointer doesn't arrive.
    func pointerLeft(snapshotID: String) {
        guard shownSnapshotID == snapshotID else { return }
        scheduleHide()
    }

    /// Hides the card if it still belongs to this row. When the pointer moves
    /// between rows, the new row's hover can arrive before the old row's exit.
    func hide(snapshotID: String) {
        guard shownSnapshotID == snapshotID else { return }
        shownSnapshotID = nil
        shownSnapshot = nil
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
        guard shownSnapshotID != nil, let panel else { return }
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
        guard !isPointerOnCard, let id = shownSnapshotID else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hideDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isPointerOnCard else { return }
            self.hide(snapshotID: id)
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

    func closeAndOpenBranches() {
        if let shownSnapshotID { hide(snapshotID: shownSnapshotID) }
        openBranches()
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
            openBranches: { [weak self] in self?.closeAndOpenBranches() }
        )
        cardFrame = placement.cardFrame
        let railEdge = placement.arrowEdge == .leading ? rail.frame.maxX : rail.frame.minX
        let minX = min(railEdge, cardFrame.minX)
        keepOpenFrame = CGRect(
            x: minX,
            y: cardFrame.minY,
            width: max(railEdge, cardFrame.maxX) - minX,
            height: cardFrame.height
        )
        panel.setFrame(placement.cardFrame.insetBy(dx: -inset, dy: -inset), display: true)
        panel.level = rail.level
        // As a child window the card follows the rail when it is dragged.
        if panel.parent == nil { rail.addChildWindow(panel, ordered: .above) }
    }

    private func cardView(showing content: RailDetailCard.Content) -> NSHostingView<RailDetailCard> {
        let card = RailDetailCard(content: content, openBranches: { [weak self] in self?.closeAndOpenBranches() })
        if let hostingView {
            hostingView.rootView = card
            return hostingView
        }
        let view = NSHostingView(rootView: card)
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
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Until the pointer is on the card itself, so its margin can't take
        // hover from the rail.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
}
